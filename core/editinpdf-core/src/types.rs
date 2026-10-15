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

#[cfg(test)]
mod tests {
    use super::PageInfo;

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
}
