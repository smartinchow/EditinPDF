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

#[cfg(test)]
mod tests {
    use super::{PageInfo, RenderedTile};

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
}
