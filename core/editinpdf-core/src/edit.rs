//! Editing: the changes the apps can make to a document, and the records that describe them.
//!
//! Pages are 0-based and every coordinate is in view space (points from the page's top-left corner
//! as shown, after its rotation, `y` growing down). Only this module turns them into the engine's
//! edits.

use std::sync::Arc;

use crate::EditError;

/// The largest page side a blank page may have, in points: 200 inches, the most a PDF page can
/// measure (ISO 32000-1, Annex C).
const MAX_PAGE_SIDE_PT: f64 = 14_400.0;

/// A point in view space: points from the page's top-left corner as shown.
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// A colour, each component from 0 through 1. (Not `Color`, which SwiftUI already has.)
#[derive(uniffi::Record, Clone, Copy, Debug, PartialEq)]
pub struct RgbColor {
    pub red: f64,
    pub green: f64,
    pub blue: f64,
}

/// How marked-up text is marked.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq)]
pub enum MarkupKind {
    Highlight,
    Underline,
    StrikeOut,
}

/// The outline of a drawn shape.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq)]
pub enum ShapeKind {
    Rectangle,
    Oval,
}

/// What a form field is set to.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum FieldValue {
    /// A text field's text.
    Text { text: String },
    /// A check box: on or off.
    Checked { on: bool },
    /// A radio group: the state of the button that is on, or none.
    Radio { state: Option<String> },
    /// A list or combo box: the values chosen.
    Choice { values: Vec<String> },
}

/// How a document is written.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq)]
pub enum SaveMode {
    /// The file as opened, with the changes appended: quick, and keeps signatures valid.
    Incremental,
    /// A complete, compact rewrite. Refused for a signed document.
    Full,
}

/// What a successful edit, undo or redo did.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct EditOutcome {
    /// The document's revision now.
    pub revision: u64,
    /// What the change is called, in English ("Rotate pages"), for the Edit menu.
    pub label: String,
}

/// What can be done to a document.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct EditCapabilities {
    /// The document's content and information can be changed.
    pub can_edit: bool,
    /// Why the document cannot be edited at all, when it cannot.
    pub read_only_reason: Option<String>,
    /// Pages can be rotated, deleted, moved and inserted.
    pub can_organize: bool,
    /// Comments can be added and changed.
    pub can_annotate: bool,
    /// Form fields can be filled in.
    pub can_fill_forms: bool,
    /// At least one signature field holds a signature.
    pub is_signed: bool,
}

/// A change to a document. Pages are 0-based.
#[derive(uniffi::Enum, Clone, Debug, PartialEq)]
pub enum Edit {
    /// Turns `pages` by `degrees`, a multiple of 90; positive turns clockwise.
    RotatePages { pages: Vec<u32>, degrees: i32 },
    /// Removes `pages`. A document keeps at least one page.
    DeletePages { pages: Vec<u32> },
    /// Moves `pages`, in document order, so that the first of them is at index `to` in the result.
    MovePages { pages: Vec<u32>, to: u32 },
    /// Inserts a blank page of the given size, in points, so that it is at index `at`.
    InsertBlankPage {
        at: u32,
        width_pt: f64,
        height_pt: f64,
    },
    /// Sets a document information entry (`Title`, `Author`, …).
    SetInfo { key: String, value: String },
    /// Inserts pages of another PDF, `bytes`, so that the first of them is at index `at`: the
    /// source's `pages` in the order given, or all of them in order when `pages` is `None`. `name`
    /// names the source in the change's label ("Insert pages from report.pdf").
    InsertPagesFrom {
        name: String,
        bytes: Vec<u8>,
        pages: Option<Vec<u32>>,
        at: u32,
    },
}

impl Edit {
    /// The engine's edit for this one, once its values are checked.
    ///
    /// `pages` is the document's pages as they are before the edit, which an edit with a position
    /// on a page converts against.
    pub(crate) fn to_engine(
        &self,
        _pages: &[pdfcraft_render::PageInfo],
    ) -> Result<pdfcraft_engine::Edit, EditError> {
        use pdfcraft_engine::Edit as Engine;
        Ok(match self {
            Self::RotatePages { pages, degrees } => {
                if degrees % 90 != 0 {
                    return Err(invalid(format!(
                        "a page turns by a multiple of 90 degrees, not {degrees}"
                    )));
                }
                Engine::RotatePages {
                    pages: indices(pages)?,
                    degrees: i64::from(*degrees),
                }
            }
            Self::DeletePages { pages } => Engine::DeletePages {
                pages: indices(pages)?,
            },
            Self::MovePages { pages, to } => Engine::MovePages {
                pages: indices(pages)?,
                to: index(*to)?,
            },
            Self::InsertBlankPage {
                at,
                width_pt,
                height_pt,
            } => Engine::InsertBlankPage {
                at: index(*at)?,
                width: page_side(*width_pt)?,
                height: page_side(*height_pt)?,
            },
            Self::SetInfo { key, value } => Engine::SetInfo {
                key: key.clone(),
                value: value.clone(),
            },
            Self::InsertPagesFrom {
                name,
                bytes,
                pages,
                at,
            } => {
                let bytes = Arc::new(bytes.clone());
                source_check(&bytes)?;
                Engine::InsertPagesFrom {
                    name: name.clone(),
                    bytes,
                    pages: pages.as_deref().map(indices).transpose()?,
                    at: index(*at)?,
                    field_conflicts: pdfcraft_organize::FieldConflicts::Rename,
                }
            }
        })
    }

    /// Whether the edit changes which pages there are, their order or their rotation: after it,
    /// a position on a page no longer means what it did.
    pub(crate) fn is_page_structure(&self) -> bool {
        match self {
            Self::RotatePages { .. }
            | Self::DeletePages { .. }
            | Self::MovePages { .. }
            | Self::InsertBlankPage { .. }
            | Self::InsertPagesFrom { .. } => true,
            Self::SetInfo { .. } => false,
        }
    }

    /// Whether the edit carries a position on a page, which is converted against the pages as they
    /// are before it.
    pub(crate) fn has_geometry(&self) -> bool {
        match self {
            Self::RotatePages { .. }
            | Self::DeletePages { .. }
            | Self::MovePages { .. }
            | Self::InsertBlankPage { .. }
            | Self::SetInfo { .. }
            | Self::InsertPagesFrom { .. } => false,
        }
    }
}

fn invalid(message: String) -> EditError {
    EditError::Invalid { message }
}

/// A page index as the engine takes it.
fn index(page: u32) -> Result<usize, EditError> {
    usize::try_from(page).map_err(|_| invalid(format!("page {page} does not exist")))
}

fn indices(pages: &[u32]) -> Result<Vec<usize>, EditError> {
    pages.iter().map(|page| index(*page)).collect()
}

/// Whether the engine can take pages from `bytes`, as a typed error when it cannot: a source that
/// needs a password, or one it cannot read or whose security settings forbid copying its pages.
fn source_check(bytes: &Arc<Vec<u8>>) -> Result<(), EditError> {
    use pdfcraft_engine::SourceProblem;
    pdfcraft_engine::combine_source_check(bytes, None).map_err(|problem| match problem {
        SourceProblem::Password => EditError::SourceNeedsPassword,
        SourceProblem::WrongPassword
        | SourceProblem::NotPermitted
        | SourceProblem::Unreadable(_) => EditError::SourceUnreadable {
            message: problem.to_string(),
        },
    })
}

/// A blank page's side, once it is known to be a size a page can have.
pub(crate) fn page_side(points: f64) -> Result<f64, EditError> {
    if points.is_finite() && points > 0.0 && points <= MAX_PAGE_SIDE_PT {
        Ok(points)
    } else {
        Err(invalid(format!(
            "a page side is more than 0 and at most {MAX_PAGE_SIDE_PT} points, not {points}"
        )))
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn turns_and_sizes_are_checked() {
        let ok = Edit::RotatePages {
            pages: vec![0, 2],
            degrees: -270,
        };
        assert_eq!(
            ok.to_engine(&[]).unwrap(),
            pdfcraft_engine::Edit::RotatePages {
                pages: vec![0, 2],
                degrees: -270
            }
        );
        for degrees in [45, 1, -91] {
            let bad = Edit::RotatePages {
                pages: vec![0],
                degrees,
            };
            assert!(matches!(bad.to_engine(&[]), Err(EditError::Invalid { .. })));
        }
        for side in [0.0, -1.0, f64::NAN, f64::INFINITY, 14_400.5] {
            let bad = Edit::InsertBlankPage {
                at: 0,
                width_pt: side,
                height_pt: 100.0,
            };
            assert!(matches!(bad.to_engine(&[]), Err(EditError::Invalid { .. })));
        }
        let largest = Edit::InsertBlankPage {
            at: 1,
            width_pt: 14_400.0,
            height_pt: 1.0,
        };
        assert!(largest.to_engine(&[]).is_ok());
    }
}
