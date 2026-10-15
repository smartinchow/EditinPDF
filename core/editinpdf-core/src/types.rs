//! Plain records that cross the FFI boundary.

/// One page's geometry and label, as the viewer lays it out.
///
/// Sizes are PDF points (1/72 inch) in *view space*: the page as shown, after its `/Rotate` (and
/// `/UserUnit`) are applied. A US Letter page with `/Rotate 90` is therefore 792 wide and 612 tall.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct PageInfo {
    /// The page's 0-based index in the document.
    pub index: u32,
    /// Width of the page as shown, in points.
    pub width_pt: f64,
    /// Height of the page as shown, in points.
    pub height_pt: f64,
    /// The page's clockwise `/Rotate` (0, 90, 180 or 270); the sizes above already include it.
    pub rotation_degrees: u32,
    /// The label the document gives the page (for example "iv"); nothing when the page is simply
    /// known by its 1-based number.
    pub label: Option<String>,
}

impl PageInfo {
    /// The record for page `index`, from what the engine read when the document was opened.
    pub(crate) fn from_engine(index: u32, page: &pdfcraft_render::PageInfo) -> Self {
        // The engine always supplies a label and falls back to the 1-based page number, so a
        // label equal to that number is not one the document defines.
        let numbered = (u64::from(index) + 1).to_string();
        Self {
            index,
            width_pt: f64::from(page.width),
            height_pt: f64::from(page.height),
            rotation_degrees: u32::from(page.rotation),
            label: (page.label != numbered).then(|| page.label.clone()),
        }
    }
}

/// A region of a page, in device pixels at the scale it is drawn at, counted from the top-left
/// corner of the page as shown (after its rotation).
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct TileRect {
    /// Distance from the page's left edge to the region's left edge, in pixels.
    pub x: u32,
    /// Distance from the page's top edge to the region's top edge, in pixels.
    pub y: u32,
    /// Width in pixels: 1 to 4096.
    pub width: u32,
    /// Height in pixels: 1 to 4096.
    pub height: u32,
}

/// The pixels of a drawn page or tile: `width` by `height` pixels, row by row from the top-left
/// corner, each pixel four bytes (red, green, blue, alpha) with the colours premultiplied by alpha.
///
/// `rgba` holds exactly `width * height * 4` bytes. The page is drawn over an opaque background, so
/// every alpha byte is 255 and premultiplied colours equal plain ones.
#[derive(uniffi::Record, Clone)]
pub struct RenderedTile {
    /// Width in pixels.
    pub width: u32,
    /// Height in pixels.
    pub height: u32,
    /// The pixel bytes.
    pub rgba: Vec<u8>,
}

impl std::fmt::Debug for RenderedTile {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The pixels are the page's contents, and a page's worth of numbers would drown a log or a
        // failed assertion; say how many there are instead.
        f.debug_struct("RenderedTile")
            .field("width", &self.width)
            .field("height", &self.height)
            .field("rgba", &format_args!("{} bytes", self.rgba.len()))
            .finish()
    }
}

/// A rectangle on a page, in points (1/72 inch) in *view space*: measured from the top-left corner
/// of the page as shown (after its `/Rotate`), with `x` growing to the right and `y` growing down.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    /// Distance from the page's left edge to the rectangle's left edge.
    pub x: f64,
    /// Distance from the page's top edge to the rectangle's top edge.
    pub y: f64,
    /// Width: the distance from the left edge to the right edge.
    pub width: f64,
    /// Height: the distance from the top edge to the bottom edge.
    pub height: f64,
}

impl Rect {
    /// The record for a box the engine reports as `[left, top, right, bottom]`.
    ///
    /// The engine's text boxes are in view space already, so nothing is turned or shifted here:
    /// this is the one place they become records.
    pub(crate) fn from_engine(rect: [f32; 4]) -> Self {
        // Widened before subtracting: for page-sized numbers the difference of two single
        // precision values is exact in double precision, so `x + width` is the engine's right edge.
        let [left, top, right, bottom] = rect.map(f64::from);
        Self {
            x: left,
            y: top,
            width: right - left,
            height: bottom - top,
        }
    }
}

/// One glyph of a page's text: the characters it stands for and the box it takes up on the page.
///
/// A glyph is usually one character. A ligature such as "fi" is one glyph standing for several, and
/// the space between two words is a glyph of its own when the page draws one.
#[derive(uniffi::Record, Clone, Debug)]
pub struct TextGlyph {
    /// The glyph's text: one character, or several for a ligature.
    pub text: String,
    /// The box the glyph takes up, in view space.
    pub rect: Rect,
}

/// The text of one page: its glyphs in reading order. A page without text, such as a scan, has no
/// glyphs.
///
/// A glyph is known by its index in `glyphs`. Selections and search hits name their glyphs by these
/// indices, which stay the same for as long as the document's revision does.
#[derive(uniffi::Record, Clone)]
pub struct PageText {
    /// The page's glyphs, in reading order.
    pub glyphs: Vec<TextGlyph>,
}

impl PageText {
    /// The record for the text the engine extracted from a page.
    pub(crate) fn from_engine(text: &pdfcraft_render::PageText) -> Self {
        Self {
            glyphs: text
                .glyphs
                .iter()
                .map(|glyph| TextGlyph {
                    text: glyph.text.clone(),
                    rect: Rect::from_engine(glyph.rect),
                })
                .collect(),
        }
    }
}

impl std::fmt::Debug for PageText {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        // The glyphs are the page's text, which is the document's business, and a page's worth of
        // them would drown a log or a failed assertion; say how many there are instead.
        f.debug_struct("PageText")
            .field("glyph_count", &self.glyphs.len())
            .finish()
    }
}

/// A run of one page's text, as a tap on a word or a drag between two glyphs selects it.
///
/// `start` and `end` are glyph indices into the page's `PageText`: the selection covers the glyphs
/// from `start` up to, but not including, `end`. They stay valid for as long as the document's
/// revision stays the same.
#[derive(uniffi::Record, Clone, Debug)]
pub struct TextSelection {
    /// The 0-based page the text is on.
    pub page: u32,
    /// The index of the first selected glyph.
    pub start: u32,
    /// The index one past the last selected glyph, so `end - start` glyphs are selected.
    pub end: u32,
    /// The boxes to highlight, in view space and in reading order: one for each line the selection
    /// runs across, with that line's selected glyphs merged into it.
    pub rects: Vec<Rect>,
    /// The selected text as it reads: the spaces between words and the line breaks between lines
    /// are there, whether or not the page draws them as glyphs.
    pub text: String,
}

/// One place a search found its text.
///
/// `start` and `end` are glyph indices into the page's `PageText`, as in `TextSelection`: the match
/// covers the glyphs from `start` up to, but not including, `end`, and the indices stay valid for as
/// long as the document's revision stays the same.
#[derive(uniffi::Record, Clone, Debug)]
pub struct SearchHit {
    /// The 0-based page the match is on.
    pub page: u32,
    /// The index of the match's first glyph.
    pub start: u32,
    /// The index one past the match's last glyph.
    pub end: u32,
    /// The boxes to highlight, in view space: one for each line the match runs across.
    pub rects: Vec<Rect>,
    /// The line the match starts on, to show it in context: trimmed, and at most 80 characters.
    /// A longer line is cut down to the part around the match.
    pub snippet: String,
}

#[cfg(test)]
mod tests {
    use super::{PageInfo, PageText, Rect, RenderedTile};

    fn engine_page(label: &str, rotation: u16) -> pdfcraft_render::PageInfo {
        pdfcraft_render::PageInfo {
            width: 792.0,
            height: 612.0,
            label: label.to_owned(),
            crop: [0.0, 0.0, 612.0, 792.0],
            rotation,
        }
    }

    #[test]
    fn copies_view_space_size_and_rotation() {
        let page = PageInfo::from_engine(4, &engine_page("5", 90));
        assert_eq!(
            (
                page.index,
                page.width_pt,
                page.height_pt,
                page.rotation_degrees
            ),
            (4, 792.0, 612.0, 90)
        );
    }

    #[test]
    fn the_default_page_number_is_not_a_label() {
        assert_eq!(PageInfo::from_engine(4, &engine_page("5", 0)).label, None);
    }

    #[test]
    fn a_label_the_document_defines_is_kept() {
        assert_eq!(
            PageInfo::from_engine(4, &engine_page("iv", 0))
                .label
                .as_deref(),
            Some("iv")
        );
        // Same digits as another page's number, but not this page's.
        assert_eq!(
            PageInfo::from_engine(0, &engine_page("5", 0))
                .label
                .as_deref(),
            Some("5")
        );
    }

    #[test]
    fn a_rendered_tiles_debug_text_leaves_out_the_pixels() {
        let tile = RenderedTile {
            width: 1,
            height: 1,
            rgba: vec![11, 22, 33, 255],
        };
        let text = format!("{tile:?}");
        assert!(text.contains("4 bytes"), "{text}");
        assert!(!text.contains("33"), "{text}");
    }

    #[test]
    fn a_box_becomes_its_left_and_top_edges_and_its_size() {
        let rect = Rect::from_engine([1.5, 2.0, 4.0, 8.25]);
        assert_eq!(
            rect,
            Rect {
                x: 1.5,
                y: 2.0,
                width: 2.5,
                height: 6.25
            }
        );
    }

    #[test]
    fn a_boxs_right_and_bottom_edges_are_the_engines_to_the_last_bit() {
        // Edges that single precision cannot write exactly, as the engine's real ones are.
        for edge in [[79.942, 74.2, 86.058, 85.2], [706.8, 72.0, 717.8, 79.942]] {
            let rect = Rect::from_engine(edge);
            assert_eq!(rect.x + rect.width, f64::from(edge[2]), "{edge:?}");
            assert_eq!(rect.y + rect.height, f64::from(edge[3]), "{edge:?}");
        }
    }

    #[test]
    fn a_page_text_has_a_glyph_for_each_engine_glyph() {
        let glyph = |text: &str, rect: [f32; 4]| pdfcraft_render::TextGlyph {
            text: text.to_owned(),
            rect,
            quad: [[0.0; 2]; 4],
            direction: [1.0, 0.0],
        };
        let engine = pdfcraft_render::PageText {
            glyphs: vec![
                glyph("\u{fb01}", [10.0, 20.0, 30.0, 40.0]),
                glyph(" ", [30.0, 20.0, 35.0, 40.0]),
            ],
            line_of: vec![0, 0],
            space_before: vec![false, false],
        };
        let text = PageText::from_engine(&engine);
        assert_eq!(text.glyphs.len(), 2);
        assert_eq!(text.glyphs[0].text, "\u{fb01}");
        assert_eq!(
            text.glyphs[0].rect,
            Rect {
                x: 10.0,
                y: 20.0,
                width: 20.0,
                height: 20.0
            }
        );
        assert_eq!(text.glyphs[1].text, " ");
        assert!(
            PageText::from_engine(&pdfcraft_render::PageText::default())
                .glyphs
                .is_empty()
        );
    }

    #[test]
    fn a_page_texts_debug_text_leaves_out_the_text() {
        let text = PageText {
            glyphs: vec![super::TextGlyph {
                text: "secret".to_owned(),
                rect: Rect::from_engine([0.0; 4]),
            }],
        };
        let shown = format!("{text:?}");
        assert!(shown.contains("glyph_count: 1"), "{shown}");
        assert!(!shown.contains("secret"), "{shown}");
    }
}
