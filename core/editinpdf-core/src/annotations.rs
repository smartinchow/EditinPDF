//! The document's comments (annotations), as the apps list and address them.

use crate::geometry;
use crate::{Rect, RgbColor};

/// What kind of comment an annotation is.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum AnnotationKind {
    /// A sticky note (`/Text`).
    Note,
    Highlight,
    Underline,
    StrikeOut,
    Squiggly,
    /// A freehand drawing (`/Ink`).
    Ink,
    /// Text typed on the page (`/FreeText`).
    TextBox,
    /// A rectangle (`/Square`).
    Rectangle,
    /// An oval (`/Circle`).
    Oval,
    Line,
    Stamp,
    /// Any other kind, by its PDF subtype name.
    Other {
        subtype: String,
    },
}

impl AnnotationKind {
    fn from_subtype(subtype: &str) -> Self {
        match subtype {
            "Text" => Self::Note,
            "Highlight" => Self::Highlight,
            "Underline" => Self::Underline,
            "StrikeOut" => Self::StrikeOut,
            "Squiggly" => Self::Squiggly,
            "Ink" => Self::Ink,
            "FreeText" => Self::TextBox,
            "Square" => Self::Rectangle,
            "Circle" => Self::Oval,
            "Line" => Self::Line,
            "Stamp" => Self::Stamp,
            other => Self::Other {
                subtype: other.to_owned(),
            },
        }
    }
}

/// One comment on a page.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AnnotationInfo {
    /// The 0-based page it is on.
    pub page: u32,
    /// Its position in the page's list of annotations (`/Annots`): what deleting, moving or
    /// changing it addresses. It changes when an earlier one on the page is deleted, and with
    /// every undo and redo, so read the list again after any change.
    pub index: u32,
    pub kind: AnnotationKind,
    /// Where it is, in view space.
    pub rect: Rect,
    /// Its text.
    pub contents: Option<String>,
    /// Who the file says wrote it.
    pub author: Option<String>,
    /// When it was last changed, as the file gives it (a PDF date, `D:…`).
    pub modified: Option<String>,
    pub color: Option<RgbColor>,
    /// The file forbids moving, changing or deleting it.
    pub locked: bool,
}

/// The comments of the document the engine read, page by page and top to bottom within a page.
/// Replies to other comments are left out: they belong to the comment they answer.
pub(crate) fn list(info: &pdfcraft_render::DocInfo) -> Vec<AnnotationInfo> {
    let mut list: Vec<AnnotationInfo> = info
        .annotations
        .iter()
        .filter(|a| a.in_reply_to.is_none())
        .filter_map(|a| {
            let page = info.pages.get(a.page)?;
            Some(AnnotationInfo {
                page: u32::try_from(a.page).ok()?,
                index: u32::try_from(a.index).ok()?,
                kind: AnnotationKind::from_subtype(&a.subtype),
                rect: geometry::rect_to_view(page, a.rect),
                contents: a.contents.clone(),
                author: a.author.clone(),
                modified: a.modified.clone(),
                color: a.color.map(|[red, green, blue]| RgbColor {
                    red: f64::from(red),
                    green: f64::from(green),
                    blue: f64::from(blue),
                }),
                locked: a.locked,
            })
        })
        .collect();
    list.sort_by(|a, b| {
        a.page
            .cmp(&b.page)
            .then(a.rect.y.total_cmp(&b.rect.y))
            .then(a.rect.x.total_cmp(&b.rect.x))
            .then(a.index.cmp(&b.index))
    });
    list
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn subtypes_become_kinds() {
        let cases = [
            ("Text", AnnotationKind::Note),
            ("Highlight", AnnotationKind::Highlight),
            ("Underline", AnnotationKind::Underline),
            ("StrikeOut", AnnotationKind::StrikeOut),
            ("Squiggly", AnnotationKind::Squiggly),
            ("Ink", AnnotationKind::Ink),
            ("FreeText", AnnotationKind::TextBox),
            ("Square", AnnotationKind::Rectangle),
            ("Circle", AnnotationKind::Oval),
            ("Line", AnnotationKind::Line),
            ("Stamp", AnnotationKind::Stamp),
            (
                "Caret",
                AnnotationKind::Other {
                    subtype: "Caret".to_owned(),
                },
            ),
        ];
        for (subtype, kind) in cases {
            assert_eq!(AnnotationKind::from_subtype(subtype), kind);
        }
    }
}
