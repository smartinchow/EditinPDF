#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
use editinpdf_core::{PdfDocument, RenderError, RenderedTile, TileRect};
use pdfcraft_engine::Algorithm;

/// Pixels that are fully opaque and visibly dark: what black text on a white page leaves.
fn opaque_non_white(t: &RenderedTile) -> usize {
    t.rgba
        .as_chunks::<4>()
        .0
        .iter()
        .filter(|p| p[3] == 255 && (p[0] < 200 || p[1] < 200 || p[2] < 200))
        .count()
}

/// The largest difference in any one byte between two same-sized pixel buffers.
fn largest_difference(a: &[u8], b: &[u8]) -> Option<u8> {
    assert_eq!(a.len(), b.len(), "the buffers differ in size");
    a.iter().zip(b).map(|(a, b)| a.abs_diff(*b)).max()
}

/// The `w` x `h` block of `t` whose top-left pixel is `(x, y)`, row by row.
fn block(t: &RenderedTile, x: usize, y: usize, w: usize, h: usize) -> Vec<u8> {
    let stride = t.width as usize * 4;
    (y..y + h)
        .flat_map(|row| t.rgba[row * stride + x * 4..][..w * 4].iter().copied())
        .collect()
}

#[test]
fn whole_page_dimensions_follow_scale() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello tile"]), None).unwrap();
    let t = doc.render_tile(0, 0.5, None).unwrap();
    assert_eq!((t.width, t.height), (306, 396));
    assert_eq!(t.rgba.len(), 306 * 396 * 4);
    assert!(opaque_non_white(&t) > 20, "text should produce dark pixels");
}

#[test]
fn the_page_is_drawn_on_opaque_white() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello tile"]), None).unwrap();
    let t = doc.render_tile(0, 1.0, None).unwrap();
    // The margin (the top-left corner, 1 inch from the text) is plain white, and no pixel anywhere
    // is see-through, so the viewer can treat the buffer as opaque.
    assert_eq!(&t.rgba[..4], &[255, 255, 255, 255]);
    assert!(t.rgba.as_chunks::<4>().0.iter().all(|p| p[3] == 255));
}

#[test]
fn tile_matches_request_and_is_a_crop() {
    let doc = PdfDocument::open(fixtures::text_doc(&["Hello tile"]), None).unwrap();
    let full = doc.render_tile(0, 2.0, None).unwrap(); // 1224 × 1584
    assert_eq!((full.width, full.height), (1224, 1584));
    let tile = doc
        .render_tile(
            0,
            2.0,
            Some(TileRect {
                x: 100,
                y: 100,
                width: 256,
                height: 256,
            }),
        )
        .unwrap();
    assert_eq!((tile.width, tile.height), (256, 256));
    assert_eq!(tile.rgba.len(), 256 * 256 * 4);
    // pixel (0,0) of the tile == pixel (100,100) of the full render
    let full_px = &full.rgba[((100 * 1224 + 100) * 4)..][..4];
    assert_eq!(&tile.rgba[..4], full_px);
    // ...and so is every other pixel: the tile is the same picture, cut out. The cut-out holds
    // the start of the text, so a tile drawn from the wrong offset could not match by being blank.
    assert!(opaque_non_white(&tile) > 20, "the tile should contain text");
    // The rasteriser works in floating point and draws a tile shifted by its offset, so an
    // anti-aliased edge pixel can come out a level apart (1 pixel of these 65,536 does, by 1 of
    // 255). Two levels are allowed in any channel; a wrong offset is off by far more than that at
    // every edge of every glyph.
    let worst = largest_difference(&tile.rgba, &block(&full, 100, 100, 256, 256));
    assert!(worst <= Some(2), "largest channel difference {worst:?}");
}

#[test]
fn a_tile_of_a_rotated_page_is_a_crop_of_the_page_as_shown() {
    // After /Rotate 90 the text runs down the right-hand side of the landscape page. Tile
    // coordinates are those of the page as shown, so the tile is cut from the rotated picture.
    let doc = PdfDocument::open(fixtures::rotated_doc("turned text"), None).unwrap();
    let full = doc.render_tile(0, 1.0, None).unwrap();
    assert_eq!((full.width, full.height), (792, 612));
    let tile = doc
        .render_tile(
            0,
            1.0,
            Some(TileRect {
                x: 560,
                y: 40,
                width: 232,
                height: 200,
            }),
        )
        .unwrap();
    assert_eq!((tile.width, tile.height), (232, 200));
    assert!(
        opaque_non_white(&tile) > 20,
        "the tile should hold the turned text"
    );
    let worst = largest_difference(&tile.rgba, &block(&full, 560, 40, 232, 200));
    assert!(worst <= Some(2), "largest channel difference {worst:?}");
}

#[test]
fn deep_zoom_tile_never_allocates_the_page() {
    let doc = PdfDocument::open(fixtures::text_doc(&["zoom"]), None).unwrap();
    // The page is 12240 x 15840 px at this scale: 194 Mpx, far beyond the renderer's whole-page cap.
    let t = doc
        .render_tile(
            0,
            20.0,
            Some(TileRect {
                x: 4000,
                y: 4000,
                width: 1024,
                height: 1024,
            }),
        )
        .unwrap();
    assert_eq!((t.width, t.height), (1024, 1024));
    assert_eq!(t.rgba.len(), 1024 * 1024 * 4);
}

#[test]
fn deep_zoom_tile_shows_the_page_content() {
    let doc = PdfDocument::open(fixtures::text_doc(&["zoom"]), None).unwrap();
    // The first line starts 1 inch (1440 px at this scale) from the top-left corner, so this tile
    // covers the start of the word, drawn about 220 px tall.
    let t = doc
        .render_tile(
            0,
            20.0,
            Some(TileRect {
                x: 1400,
                y: 1400,
                width: 1024,
                height: 1024,
            }),
        )
        .unwrap();
    assert_eq!((t.width, t.height), (1024, 1024));
    assert!(
        opaque_non_white(&t) > 5_000,
        "large glyphs should cover many pixels"
    );
}

#[test]
fn a_tile_may_overhang_the_page_edge() {
    let doc = PdfDocument::open(fixtures::text_doc(&["edge"]), None).unwrap();
    // The page is 612 x 792 px at scale 1. A tile grid does not line up with the page, so tiles at
    // the right and bottom edges reach past it; the part beyond the page is white, not an error.
    let t = doc
        .render_tile(
            0,
            1.0,
            Some(TileRect {
                x: 500,
                y: 700,
                width: 256,
                height: 256,
            }),
        )
        .unwrap();
    assert_eq!((t.width, t.height), (256, 256));
    let beyond = block(&t, 200, 200, 8, 8); // page pixels (700..708, 900..908)
    assert!(
        beyond
            .as_chunks::<4>()
            .0
            .iter()
            .all(|p| *p == [255, 255, 255, 255])
    );
}

#[test]
fn a_rotated_page_renders_in_view_space() {
    let doc = PdfDocument::open(fixtures::rotated_doc("turned"), None).unwrap();
    let info = doc.page_info(0).unwrap();
    let t = doc.render_tile(0, 1.0, None).unwrap();
    // The raster is the page as shown: landscape, the same size `page_info` reports.
    assert_eq!((t.width, t.height), (792, 612));
    assert_eq!(
        (f64::from(t.width), f64::from(t.height)),
        (info.width_pt, info.height_pt)
    );
    assert!(opaque_non_white(&t) > 20, "the text should still be drawn");
}

#[test]
fn an_unlocked_document_renders() {
    // The password given at open has to reach the renderer; without it the page cannot be read.
    let bytes = fixtures::encrypted_doc(&["Hello locked"], "hunter2");
    let doc = PdfDocument::open(bytes, Some("hunter2".into())).unwrap();
    let t = doc.render_tile(0, 0.5, None).unwrap();
    assert_eq!((t.width, t.height), (306, 396));
    assert!(opaque_non_white(&t) > 20, "text should produce dark pixels");
}

#[test]
fn a_document_opened_with_its_owner_password_renders() {
    // Either password opens the file. Older (R2-R4) encryption cannot be drawn with the owner
    // password, so what the renderer is given has to be the engine's, not simply what was typed.
    for algorithm in [Algorithm::Rc4_128, Algorithm::Aes128, Algorithm::Aes256] {
        let bytes = fixtures::protected_doc(&["Hello owner"], "user-pw", "owner-pw", algorithm);
        for password in ["user-pw", "owner-pw"] {
            let doc = PdfDocument::open(bytes.clone(), Some(password.into())).unwrap();
            let t = doc.render_tile(0, 0.5, None).unwrap();
            assert!(
                opaque_non_white(&t) > 20,
                "{algorithm:?} opened with the {password}"
            );
        }
    }
}

#[test]
fn errors() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    assert!(matches!(
        doc.render_tile(5, 1.0, None),
        Err(RenderError::PageOutOfRange { page: 5 })
    ));
    assert!(matches!(
        doc.render_tile(
            0,
            1.0,
            Some(TileRect {
                x: 0,
                y: 0,
                width: 5000,
                height: 10
            })
        ),
        Err(RenderError::TileTooLarge)
    ));
}

#[test]
fn the_page_range_is_checked_for_every_kind_of_request() {
    let doc = PdfDocument::open(fixtures::text_doc(&["one", "two"]), None).unwrap();
    // One past the last page, and the largest index there is.
    for page in [2, u32::MAX] {
        assert!(
            matches!(
                doc.render_tile(page, 1.0, None),
                Err(RenderError::PageOutOfRange { page: p }) if p == page
            ),
            "whole page {page}"
        );
        let tile = Some(TileRect {
            x: 0,
            y: 0,
            width: 16,
            height: 16,
        });
        assert!(
            matches!(
                doc.render_tile(page, 1.0, tile),
                Err(RenderError::PageOutOfRange { page: p }) if p == page
            ),
            "tile of page {page}"
        );
    }
    // The last page itself is fine.
    assert!(doc.render_tile(1, 0.25, None).is_ok());
}

#[test]
fn tile_sides_must_be_between_1_and_4096() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    let tile = |width, height| {
        doc.render_tile(
            0,
            1.0,
            Some(TileRect {
                x: 0,
                y: 0,
                width,
                height,
            }),
        )
    };
    // Too wide, too tall, and a tile with no area at all (zero width or height, the same error).
    for (width, height) in [
        (4097, 16),
        (16, 4097),
        (0, 16),
        (16, 0),
        (0, 0),
        (u32::MAX, 1),
    ] {
        assert!(
            matches!(tile(width, height), Err(RenderError::TileTooLarge)),
            "{width} x {height}"
        );
    }
    // The limits themselves are fine, in each direction.
    let wide = tile(4096, 1).unwrap();
    assert_eq!((wide.width, wide.height), (4096, 1));
    let tall = tile(1, 4096).unwrap();
    assert_eq!((tall.width, tall.height), (1, 4096));
}

#[test]
fn a_scale_that_is_not_a_positive_number_is_rejected() {
    let doc = PdfDocument::open(fixtures::text_doc(&["x"]), None).unwrap();
    let tile = Some(TileRect {
        x: 0,
        y: 0,
        width: 16,
        height: 16,
    });
    // Zero, negative, not-a-number, infinite, and values the engine's single-precision scale
    // cannot hold (it would otherwise read the tiny one as zero and draw the page at its largest).
    for scale in [
        0.0,
        -0.0,
        -1.0,
        f64::NAN,
        f64::INFINITY,
        f64::NEG_INFINITY,
        1e300,
        1e-300,
    ] {
        for rect in [None, tile] {
            let err = doc.render_tile(0, scale, rect).unwrap_err();
            assert!(
                matches!(&err, RenderError::Failed { message } if message == "invalid scale"),
                "scale {scale} rect {rect:?}: {err:?}"
            );
        }
    }
}

#[test]
fn whole_page_renders_beyond_the_size_cap_come_back_clamped() {
    let doc = PdfDocument::open(fixtures::text_doc(&["big"]), None).unwrap();
    // 612 x 792 pt at scale 20 would be 12240 x 15840 px. The engine caps a whole-page raster at
    // 8192 px on a side (and 64 Mpx); the call succeeds with the clamped picture, and the returned
    // size says what it is. Tiles are the way to zoom deeper.
    let t = doc.render_tile(0, 20.0, None).unwrap();
    assert_eq!(t.rgba.len(), t.width as usize * t.height as usize * 4);
    assert!(t.width.max(t.height) <= 8192, "{} x {}", t.width, t.height);
    assert!(u64::from(t.width) * u64::from(t.height) <= 64_000_000);
    assert_eq!(
        t.height, 8192,
        "the long side is clamped, not the short one"
    );
}

#[test]
fn concurrent_tiles() {
    let doc =
        std::sync::Arc::new(PdfDocument::open(fixtures::text_doc(&["a", "b"]), None).unwrap());
    let hs: Vec<_> = (0..8)
        .map(|i| {
            let d = doc.clone();
            std::thread::spawn(move || {
                d.render_tile(
                    i % 2,
                    1.0,
                    Some(TileRect {
                        x: 0,
                        y: 0,
                        width: 128,
                        height: 128,
                    }),
                )
                .unwrap()
                .rgba
                .len()
            })
        })
        .collect();
    for h in hs {
        assert_eq!(h.join().unwrap(), 128 * 128 * 4);
    }
}

#[test]
fn concurrent_tiles_come_out_right() {
    let doc =
        std::sync::Arc::new(PdfDocument::open(fixtures::text_doc(&["a", "b"]), None).unwrap());
    // At scale 4 the text starts 288 px in from the corner; this tile covers its first letter.
    let rect = TileRect {
        x: 280,
        y: 290,
        width: 64,
        height: 64,
    };
    // What each page looks like when nothing else is going on...
    let expected = [
        doc.render_tile(0, 4.0, Some(rect)).unwrap().rgba,
        doc.render_tile(1, 4.0, Some(rect)).unwrap().rgba,
    ];
    assert_ne!(expected[0], expected[1], "the two pages should differ");
    // ...is what it looks like while many threads draw both at once.
    let hs: Vec<_> = (0..16usize)
        .map(|i| {
            let d = doc.clone();
            std::thread::spawn(move || {
                (
                    i % 2,
                    d.render_tile((i % 2) as u32, 4.0, Some(rect)).unwrap().rgba,
                )
            })
        })
        .collect();
    for h in hs {
        let (page, rgba) = h.join().unwrap();
        assert!(
            rgba == expected[page],
            "page {page} was drawn wrongly under contention"
        );
    }
}
