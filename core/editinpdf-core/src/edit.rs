//! Editing: the changes the apps can make to a document, and the records that describe them.
//!
//! Pages are 0-based and every coordinate is in view space (points from the page's top-left corner
//! as shown, after its rotation, `y` growing down). Only this module turns them into the engine's
//! edits.

use std::sync::Arc;

use crate::{EditError, Rect, geometry};

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
    /// Marks text: `rects` are the boxes of the marked text, one for each line, as
    /// `TextSelection.rects` gives them.
    AddTextMarkup {
        page: u32,
        kind: MarkupKind,
        rects: Vec<Rect>,
        color: RgbColor,
        contents: String,
    },
    /// Adds a sticky note whose icon's top-left corner, as shown, is at `at`.
    AddNote {
        page: u32,
        at: Point,
        contents: String,
        color: RgbColor,
    },
    /// Deletes the comment at `index` in the page's list (`AnnotationInfo.index`), with its
    /// replies and pop-up.
    ///
    /// Deleting a comment moves the ones after it on the page down the list, and the engine also
    /// takes out its pop-up and replies, which have places of their own. So when one `apply_all`
    /// deletes several comments on a page, put the deletes in order of highest `index` first, so
    /// that each still addresses the comment it was meant for.
    DeleteAnnotation { page: u32, index: u32 },
    /// Changes the text of the comment at `index` in the page's list (`AnnotationInfo.index`).
    SetAnnotationContents {
        page: u32,
        index: u32,
        contents: String,
    },
}

impl Edit {
    /// The engine's edit for this one, once its values are checked.
    ///
    /// `pages` is the document's pages as they are before the edit, which an edit with a position
    /// on a page converts against.
    pub(crate) fn to_engine(
        &self,
        pages: &[pdfcraft_render::PageInfo],
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
            Self::AddTextMarkup {
                page,
                kind,
                rects,
                color,
                contents,
            } => {
                let info = page_of(pages, *page)?;
                if rects.is_empty() {
                    return Err(invalid("there is no text to mark".to_owned()));
                }
                let quads = rects
                    .iter()
                    .map(|rect| Ok(geometry::rect_to_quad(info, area(rect)?)))
                    .collect::<Result<Vec<_>, EditError>>()?;
                let markup = match kind {
                    MarkupKind::Highlight => pdfcraft_engine::Markup::Highlight,
                    MarkupKind::Underline => pdfcraft_engine::Markup::Underline,
                    MarkupKind::StrikeOut => pdfcraft_engine::Markup::StrikeOut,
                };
                comment(
                    *page,
                    pdfcraft_engine::Shape::TextMarkup {
                        kind: markup,
                        quads,
                    },
                    *color,
                    contents,
                )?
            }
            Self::AddNote {
                page,
                at,
                contents,
                color,
            } => {
                let info = page_of(pages, *page)?;
                if !(at.x.is_finite() && at.y.is_finite()) {
                    return Err(invalid(format!(
                        "a note goes at a point on the page, not ({}, {})",
                        at.x, at.y
                    )));
                }
                // The icon's box as shown, turned into the file's space: its top-left corner there
                // is where the engine puts the icon, so it covers the tapped box at any rotation.
                let shown = Rect {
                    x: at.x,
                    y: at.y,
                    width: pdfcraft_engine::NOTE_SIZE,
                    height: pdfcraft_engine::NOTE_SIZE,
                };
                let [x0, _, _, y1] = geometry::rect_to_user(info, &shown);
                comment(
                    *page,
                    pdfcraft_engine::Shape::Note {
                        at: [x0, y1],
                        icon: pdfcraft_engine::NoteIcon::default(),
                    },
                    *color,
                    contents,
                )?
            }
            Self::DeleteAnnotation { page, index } => Engine::DeleteAnnotation {
                page: index_of(pages, *page)?,
                index: annotation_index(*index)?,
            },
            Self::SetAnnotationContents {
                page,
                index,
                contents,
            } => Engine::SetAnnotationContents {
                page: index_of(pages, *page)?,
                index: annotation_index(*index)?,
                text: contents.clone(),
            },
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
            Self::SetInfo { .. }
            | Self::AddTextMarkup { .. }
            | Self::AddNote { .. }
            | Self::DeleteAnnotation { .. }
            | Self::SetAnnotationContents { .. } => false,
        }
    }

    /// Whether the edit changes which page an index stands for (deleting, moving or inserting
    /// pages; turning one leaves the numbering as it was).
    pub(crate) fn renumbers_pages(&self) -> bool {
        match self {
            Self::DeletePages { .. }
            | Self::MovePages { .. }
            | Self::InsertBlankPage { .. }
            | Self::InsertPagesFrom { .. } => true,
            Self::RotatePages { .. }
            | Self::SetInfo { .. }
            | Self::AddTextMarkup { .. }
            | Self::AddNote { .. }
            | Self::DeleteAnnotation { .. }
            | Self::SetAnnotationContents { .. } => false,
        }
    }

    /// Whether the edit addresses a comment already on a page by its page and its place in that
    /// page's list, which are read as they are before the step.
    pub(crate) fn addresses_annotation(&self) -> bool {
        match self {
            Self::DeleteAnnotation { .. } | Self::SetAnnotationContents { .. } => true,
            Self::RotatePages { .. }
            | Self::DeletePages { .. }
            | Self::MovePages { .. }
            | Self::InsertBlankPage { .. }
            | Self::SetInfo { .. }
            | Self::InsertPagesFrom { .. }
            | Self::AddTextMarkup { .. }
            | Self::AddNote { .. } => false,
        }
    }

    /// Whether the edit takes pages from another PDF, which is read only once the document is
    /// known to accept them.
    pub(crate) fn takes_source(&self) -> bool {
        matches!(self, Self::InsertPagesFrom { .. })
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
            | Self::InsertPagesFrom { .. }
            | Self::DeleteAnnotation { .. }
            | Self::SetAnnotationContents { .. } => false,
            Self::AddTextMarkup { .. } | Self::AddNote { .. } => true,
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

/// The page `page` is, as the document has it before the edit; `Invalid` when it has no such page.
fn page_of(
    pages: &[pdfcraft_render::PageInfo],
    page: u32,
) -> Result<&pdfcraft_render::PageInfo, EditError> {
    usize::try_from(page)
        .ok()
        .and_then(|index| pages.get(index))
        .ok_or_else(|| invalid(format!("page {page} does not exist")))
}

/// The engine's index of a page the document has.
fn index_of(pages: &[pdfcraft_render::PageInfo], page: u32) -> Result<usize, EditError> {
    page_of(pages, page)?;
    index(page)
}

/// A comment's position in its page's list, as the engine takes it.
fn annotation_index(position: u32) -> Result<usize, EditError> {
    usize::try_from(position).map_err(|_| invalid(format!("comment {position} does not exist")))
}

/// `rect`, once it is known to be a box with an area: finite, and wider and taller than nothing.
fn area(rect: &Rect) -> Result<&Rect, EditError> {
    let finite = [rect.x, rect.y, rect.width, rect.height]
        .iter()
        .all(|v| v.is_finite());
    if finite && rect.width > 0.0 && rect.height > 0.0 {
        Ok(rect)
    } else {
        Err(invalid(format!("{rect:?} is not an area of the page")))
    }
}

/// The engine's colour for `color`, once its components are known to be numbers; each is held
/// within 0 through 1.
fn rgb(color: RgbColor) -> Result<pdfcraft_engine::Rgb, EditError> {
    let components = [color.red, color.green, color.blue];
    if components.iter().all(|c| c.is_finite()) {
        Ok(components.map(|c| c.clamp(0.0, 1.0)))
    } else {
        Err(invalid(format!("{color:?} is not a colour")))
    }
}

/// The engine's edit adding a comment of `shape` on `page`, in the tool's usual look but `color`,
/// fully opaque. The author is left empty: the apps keep no personal data.
fn comment(
    page: u32,
    shape: pdfcraft_engine::Shape,
    color: RgbColor,
    contents: &str,
) -> Result<pdfcraft_engine::Edit, EditError> {
    let style = pdfcraft_engine::Style {
        color: rgb(color)?,
        opacity: 1.0,
        ..pdfcraft_engine::Style::default_for(&shape)
    };
    Ok(pdfcraft_engine::Edit::AddAnnotation(
        pdfcraft_engine::NewAnnotation {
            page: index(page)?,
            shape,
            style,
            contents: contents.to_owned(),
            author: String::new(),
        },
    ))
}

/// Whether the engine can take pages from `bytes`, as a typed error when it cannot: a source that
/// needs a password, one whose security settings forbid copying its pages, or one it cannot read.
fn source_check(bytes: &Arc<Vec<u8>>) -> Result<(), EditError> {
    pdfcraft_engine::combine_source_check(bytes, None).map_err(map_source_problem)
}

/// The bridge's error for why the engine cannot take pages from a source.
fn map_source_problem(problem: pdfcraft_engine::SourceProblem) -> EditError {
    use pdfcraft_engine::SourceProblem;
    // Every variant is named so that one added upstream stops the build here and gets classified.
    match problem {
        SourceProblem::Password => EditError::SourceNeedsPassword,
        SourceProblem::NotPermitted => EditError::SourceNotPermitted,
        // No password is given, so a wrong one cannot happen; were it to, the source still
        // cannot be read.
        SourceProblem::WrongPassword | SourceProblem::Unreadable(_) => {
            EditError::SourceUnreadable {
                message: problem.to_string(),
            }
        }
    }
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
    fn a_source_problem_becomes_the_matching_error() {
        assert_eq!(
            map_source_problem(pdfcraft_engine::SourceProblem::Password),
            EditError::SourceNeedsPassword
        );
        assert_eq!(
            map_source_problem(pdfcraft_engine::SourceProblem::NotPermitted),
            EditError::SourceNotPermitted
        );
        assert!(matches!(
            map_source_problem(pdfcraft_engine::SourceProblem::Unreadable("bad".to_owned())),
            EditError::SourceUnreadable { .. }
        ));
        assert!(matches!(
            map_source_problem(pdfcraft_engine::SourceProblem::WrongPassword),
            EditError::SourceUnreadable { .. }
        ));
    }

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
