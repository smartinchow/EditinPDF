//! Editing: the changes the apps can make to a document, and the records that describe them.
//!
//! Pages are 0-based and every coordinate is in view space (points from the page's top-left corner
//! as shown, after its rotation, `y` growing down). Only this module turns them into the engine's
//! edits.

use std::sync::Arc;

use crate::{EditError, Rect, annotations, forms, geometry};

/// The largest page side a blank page may have, in points: 200 inches, the most a PDF page can
/// measure (ISO 32000-1, Annex C).
const MAX_PAGE_SIDE_PT: f64 = 14_400.0;

/// The farthest from a page's view-space origin, in points, that any position, box edge or move
/// distance the apps give may be: four times the largest page side, room for anything drawn on, or
/// dragged across, any page. A finite but larger number is refused, not converted: the engine works
/// in single precision, where a number such as 1e300 becomes infinite.
const MAX_VIEW_COORD: f64 = 4.0 * MAX_PAGE_SIDE_PT;

/// The most edits one step (`PdfDocument::apply_all`) may make.
pub(crate) const MAX_STEP_EDITS: usize = 10_000;

/// The most characters (Unicode scalar values, as Rust's `char`) that the text of a comment, of a
/// text box or of a document information entry may have: 100,000, some 40 pages of prose.
///
/// A form field takes at most 10,000 (`forms::MAX_TEXT_CHARS`): it shows its text in its own small
/// box. A note can hold a long passage pasted in, so its cap is ten times that, far more than anyone
/// types or pastes into a comment. What it bounds is a hostile caller's text: the engine lays a text
/// box's text out and draws it under the document's lock, and every edit's text is kept in the undo
/// history. At the cap, a text is at most 400 KB of UTF-8.
pub(crate) const MAX_TEXT_CHARS: usize = 100_000;

/// The most boxes one text markup may cover: one for each line marked, so far more than a page has.
const MAX_MARKUP_RECTS: usize = 10_000;

/// The most strokes one drawing may have.
const MAX_STROKES: usize = 500;
/// The most points one stroke may have.
const MAX_STROKE_POINTS: usize = 10_000;
/// The most points one drawing may have, all its strokes together.
const MAX_DRAWING_POINTS: usize = 100_000;
/// The thinnest and thickest a drawn line may be, in points.
const LINE_WIDTHS: std::ops::RangeInclusive<f64> = 0.1..=50.0;
/// The smallest and largest a text box's text may be, in points.
const FONT_SIZES: std::ops::RangeInclusive<f64> = 4.0..=144.0;
/// The least a drawn box or line measures, in points.
const MIN_SIDE_PT: f64 = 1.0;

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
    /// The file as opened, with the changes appended: quick, and keeps signatures valid. A file
    /// whose cross-reference data the engine had to rebuild when it opened it has nothing to append
    /// to (`EditCapabilities::rewrites_on_save`): once it has changed it is written out in full, and
    /// a signed one is refused.
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
    /// The document is password-protected (an owner password counts, even with no open password).
    /// Pages extracted from it make a new PDF with no protection.
    pub is_encrypted: bool,
    /// Saving writes the document out in full, even an `Incremental` save, so the bytes as opened
    /// are not kept at the start of what is written: the file's cross-reference data could not be
    /// read, and the engine rebuilt it from the objects when the document opened, which leaves no
    /// chain of revisions to append to. What is written is a whole, repaired file, and later saves
    /// of that file would append to it again.
    ///
    /// A signed document like this cannot be changed at all (`can_edit` and the rest are false,
    /// with a `read_only_reason`): the first change saved would rewrite it and break its
    /// signatures.
    pub rewrites_on_save: bool,
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
    /// Sets a document information entry (`Title`, `Author`, …). The name and the value have at
    /// most `max_text_chars` characters each.
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
    /// `TextSelection.rects` gives them: at least one and at most 10,000. `contents`, the comment's
    /// text, has at most `max_text_chars` characters.
    AddTextMarkup {
        page: u32,
        kind: MarkupKind,
        rects: Vec<Rect>,
        color: RgbColor,
        contents: String,
    },
    /// Adds a sticky note whose icon's top-left corner, as shown, is at `at`. `contents` has at most
    /// `max_text_chars` characters.
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
    /// takes out its pop-up and replies, which have places of their own and can be listed before
    /// it. So in `apply_all` no other change in the step may address a comment on that page by its
    /// place, another of these deletes included (refused as `Invalid`): to delete several comments
    /// of a page at once, use `DeleteAnnotations`.
    DeleteAnnotation { page: u32, index: u32 },
    /// Deletes the comments at `indices` in page `page`'s list (`AnnotationInfo.index`, in any
    /// order; one given twice is deleted once), each with its replies and pop-up, and nothing else:
    /// one change, which one undo takes back.
    ///
    /// The places are read as the list is before the step, so in `apply_all` no other change in the
    /// step may address a comment on that page by its place (refused as `Invalid`); comments added
    /// before it, which go at the end of the list, and changes to other pages may. At least one and
    /// at most 10,000 places, each one the page's list has; a comment the file locks among them
    /// refuses the whole change, as `DeleteAnnotation` refuses it.
    DeleteAnnotations { page: u32, indices: Vec<u32> },
    /// Changes the text of the comment at `index` in the page's list (`AnnotationInfo.index`), to
    /// at most `max_text_chars` characters.
    SetAnnotationContents {
        page: u32,
        index: u32,
        contents: String,
    },
    /// Adds a freehand drawing: `strokes` are the lines drawn, each the points it passed through,
    /// `width` points wide (0.1 through 50). At most 500 strokes of at most 10 000 points, and at
    /// most 100 000 points in all; at least one stroke has a point (a stroke of one point is a dot,
    /// and empty strokes are left out).
    AddInk {
        page: u32,
        strokes: Vec<Vec<Point>>,
        color: RgbColor,
        width: f64,
    },
    /// Adds a drawn signature: strokes as for `AddInk`, kept as a signature (a drawing in the file).
    AddSignature {
        page: u32,
        strokes: Vec<Vec<Point>>,
        color: RgbColor,
        width: f64,
    },
    /// Adds a box showing `text` (at most `max_text_chars` characters) in `color`, `font_size`
    /// points (4 through 144), with no border and no background. `rect` is at least 1 point wide and
    /// tall.
    ///
    /// The engine sets the text upright in the file's own space, so on a page turned by a quarter
    /// or three quarters (`PageInfo.rotation_degrees` 90 or 270) the box is where it was drawn but
    /// its text reads sideways as shown (upside down at 180). The apps offer text boxes only on
    /// pages shown as the file has them (rotation 0).
    AddTextBox {
        page: u32,
        rect: Rect,
        text: String,
        font_size: f64,
        color: RgbColor,
    },
    /// Adds a rectangle or an oval in `rect` (at least 1 point wide and tall), outlined in `color`
    /// `width` points wide (0.1 through 50) and filled with `fill`, if any.
    AddShape {
        page: u32,
        kind: ShapeKind,
        rect: Rect,
        color: RgbColor,
        fill: Option<RgbColor>,
        width: f64,
    },
    /// Adds a line from `from` to `to` (at least 1 point apart), `width` points wide (0.1 through
    /// 50); with `arrow`, an open arrow head at `to`.
    AddLine {
        page: u32,
        from: Point,
        to: Point,
        arrow: bool,
        color: RgbColor,
        width: f64,
    },
    /// Moves the comment at `index` in the page's list (`AnnotationInfo.index`) by `dx` to the
    /// right and `dy` down, as shown, in points.
    MoveAnnotation {
        page: u32,
        index: u32,
        dx: f64,
        dy: f64,
    },
    /// Fills in the form field named `name` (`FormField.name`, matched exactly): a text field
    /// with `Text`, a check box with `Checked`, a radio group with `Radio` (a button's
    /// `FormWidget.on_state`, or none to turn them all off), a combo or list box with `Choice`
    /// (export values from `FormField.options`; a combo box that takes typed text also takes other
    /// text). A field is addressed by its name, not its page, so this goes in a step with any
    /// page change.
    SetFieldValue { name: String, value: FieldValue },
}

impl Edit {
    /// The engine's edit for this one, once its values are checked.
    ///
    /// `doc` is the document as it is before the edit: an edit with a position on a page converts
    /// it against the page as it is then, and `DeleteAnnotations` reads there which comments the
    /// places it is given are.
    pub(crate) fn to_engine(
        &self,
        doc: &pdfcraft_engine::Document,
    ) -> Result<pdfcraft_engine::Edit, EditError> {
        use pdfcraft_engine::Edit as Engine;
        let pages = &doc.info.pages;
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
                key: capped(key, "an information entry's name")?.to_owned(),
                value: capped(value, "an information entry")?.to_owned(),
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
                if rects.len() > MAX_MARKUP_RECTS {
                    return Err(invalid(format!(
                        "text markup covers at most {MAX_MARKUP_RECTS} boxes, not {}",
                        rects.len()
                    )));
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
                    capped(contents, "a comment's text")?,
                )?
            }
            Self::AddNote {
                page,
                at,
                contents,
                color,
            } => {
                let info = page_of(pages, *page)?;
                if !in_reach(*at) {
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
                    capped(contents, "a comment's text")?,
                )?
            }
            Self::DeleteAnnotation { page, index } => Engine::DeleteAnnotation {
                page: index_of(pages, *page)?,
                index: annotation_index(*index)?,
            },
            Self::DeleteAnnotations { page, indices } => {
                if indices.is_empty() {
                    return Err(invalid("there is no comment to delete".to_owned()));
                }
                if indices.len() > MAX_STEP_EDITS {
                    return Err(invalid(format!(
                        "one change deletes at most {MAX_STEP_EDITS} comments, not {}",
                        indices.len()
                    )));
                }
                annotations::deletes(doc, index_of(pages, *page)?, indices)?
            }
            Self::SetAnnotationContents {
                page,
                index,
                contents,
            } => Engine::SetAnnotationContents {
                page: index_of(pages, *page)?,
                index: annotation_index(*index)?,
                text: capped(contents, "a comment's text")?.to_owned(),
            },
            Self::AddInk {
                page,
                strokes,
                color,
                width,
            } => {
                let info = page_of(pages, *page)?;
                let shape = pdfcraft_engine::Shape::Ink {
                    strokes: strokes_to_user(info, strokes)?,
                };
                drawing(*page, shape, *color, None, line_width(*width)?)?
            }
            Self::AddSignature {
                page,
                strokes,
                color,
                width,
            } => {
                let info = page_of(pages, *page)?;
                let shape = pdfcraft_engine::Shape::Signature {
                    strokes: strokes_to_user(info, strokes)?,
                };
                drawing(*page, shape, *color, None, line_width(*width)?)?
            }
            Self::AddTextBox {
                page,
                rect,
                text,
                font_size,
                color,
            } => {
                let info = page_of(pages, *page)?;
                if !(font_size.is_finite() && FONT_SIZES.contains(font_size)) {
                    return Err(invalid(format!(
                        "text is {} through {} points, not {font_size}",
                        FONT_SIZES.start(),
                        FONT_SIZES.end()
                    )));
                }
                let shape = pdfcraft_engine::Shape::TextBox {
                    rect: geometry::rect_to_user(info, drawn_box(rect)?),
                    font_size: *font_size,
                };
                // The text's colour; no border and no background.
                comment(*page, shape, *color, capped(text, "a text box's text")?)?
            }
            Self::AddShape {
                page,
                kind,
                rect,
                color,
                fill,
                width,
            } => {
                let info = page_of(pages, *page)?;
                let rect = geometry::rect_to_user(info, drawn_box(rect)?);
                let shape = match kind {
                    ShapeKind::Rectangle => pdfcraft_engine::Shape::Rectangle { rect },
                    ShapeKind::Oval => pdfcraft_engine::Shape::Oval { rect },
                };
                drawing(*page, shape, *color, *fill, line_width(*width)?)?
            }
            Self::AddLine {
                page,
                from,
                to,
                arrow,
                color,
                width,
            } => {
                let info = page_of(pages, *page)?;
                if !(in_reach(*from) && in_reach(*to))
                    || (to.x - from.x).hypot(to.y - from.y) < MIN_SIDE_PT
                {
                    return Err(invalid(format!(
                        "a line joins two points at least {MIN_SIDE_PT} point apart, not {from:?} and {to:?}"
                    )));
                }
                let end = if *arrow {
                    pdfcraft_engine::LineEnding::OpenArrow
                } else {
                    pdfcraft_engine::LineEnding::None
                };
                let shape = pdfcraft_engine::Shape::Line {
                    from: geometry::to_user(info, *from),
                    to: geometry::to_user(info, *to),
                    start: pdfcraft_engine::LineEnding::None,
                    end,
                };
                drawing(*page, shape, *color, None, line_width(*width)?)?
            }
            Self::MoveAnnotation {
                page,
                index: position,
                dx,
                dy,
            } => {
                let info = page_of(pages, *page)?;
                if !(coordinate(*dx) && coordinate(*dy)) {
                    return Err(invalid(format!(
                        "a comment moves by at most {MAX_VIEW_COORD} points each way, not ({dx}, {dy})"
                    )));
                }
                let [dx, dy] = geometry::delta_to_user(info, *dx, *dy);
                Engine::MoveAnnotation {
                    page: index(*page)?,
                    index: annotation_index(*position)?,
                    dx,
                    dy,
                }
            }
            Self::SetFieldValue { name, value } => Engine::SetFieldValue {
                name: name.clone(),
                value: forms::value_to_engine(value)?,
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
            | Self::DeleteAnnotations { .. }
            | Self::SetAnnotationContents { .. }
            | Self::AddInk { .. }
            | Self::AddSignature { .. }
            | Self::AddTextBox { .. }
            | Self::AddShape { .. }
            | Self::AddLine { .. }
            | Self::MoveAnnotation { .. }
            | Self::SetFieldValue { .. } => false,
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
            | Self::DeleteAnnotations { .. }
            | Self::SetAnnotationContents { .. }
            | Self::AddInk { .. }
            | Self::AddSignature { .. }
            | Self::AddTextBox { .. }
            | Self::AddShape { .. }
            | Self::AddLine { .. }
            | Self::MoveAnnotation { .. }
            // A field is addressed by its name, which no page change alters.
            | Self::SetFieldValue { .. } => false,
        }
    }

    /// Whether the edit addresses a comment already on a page by its page and its place in that
    /// page's list, which are read as they are before the step.
    pub(crate) fn addresses_annotation(&self) -> bool {
        match self {
            Self::DeleteAnnotation { .. }
            | Self::DeleteAnnotations { .. }
            | Self::SetAnnotationContents { .. }
            | Self::MoveAnnotation { .. } => true,
            Self::RotatePages { .. }
            | Self::DeletePages { .. }
            | Self::MovePages { .. }
            | Self::InsertBlankPage { .. }
            | Self::SetInfo { .. }
            | Self::InsertPagesFrom { .. }
            | Self::AddTextMarkup { .. }
            | Self::AddNote { .. }
            | Self::AddInk { .. }
            | Self::AddSignature { .. }
            | Self::AddTextBox { .. }
            | Self::AddShape { .. }
            | Self::AddLine { .. }
            | Self::SetFieldValue { .. } => false,
        }
    }

    /// The page of the comments the edit addresses by their places in that page's list, when it
    /// addresses any (as `addresses_annotation` says).
    pub(crate) fn annotation_page(&self) -> Option<u32> {
        match self {
            Self::DeleteAnnotation { page, .. }
            | Self::DeleteAnnotations { page, .. }
            | Self::SetAnnotationContents { page, .. }
            | Self::MoveAnnotation { page, .. } => Some(*page),
            Self::RotatePages { .. }
            | Self::DeletePages { .. }
            | Self::MovePages { .. }
            | Self::InsertBlankPage { .. }
            | Self::SetInfo { .. }
            | Self::InsertPagesFrom { .. }
            | Self::AddTextMarkup { .. }
            | Self::AddNote { .. }
            | Self::AddInk { .. }
            | Self::AddSignature { .. }
            | Self::AddTextBox { .. }
            | Self::AddShape { .. }
            | Self::AddLine { .. }
            | Self::SetFieldValue { .. } => None,
        }
    }

    /// The name of the form field the edit fills in, when it fills one in.
    pub(crate) fn field_name(&self) -> Option<&str> {
        match self {
            Self::SetFieldValue { name, .. } => Some(name),
            Self::RotatePages { .. }
            | Self::DeletePages { .. }
            | Self::MovePages { .. }
            | Self::InsertBlankPage { .. }
            | Self::SetInfo { .. }
            | Self::InsertPagesFrom { .. }
            | Self::AddTextMarkup { .. }
            | Self::AddNote { .. }
            | Self::DeleteAnnotation { .. }
            | Self::DeleteAnnotations { .. }
            | Self::SetAnnotationContents { .. }
            | Self::AddInk { .. }
            | Self::AddSignature { .. }
            | Self::AddTextBox { .. }
            | Self::AddShape { .. }
            | Self::AddLine { .. }
            | Self::MoveAnnotation { .. } => None,
        }
    }

    /// Whether the edit takes pages from another PDF, which is read only once the document is
    /// known to accept them.
    pub(crate) fn takes_source(&self) -> bool {
        match self {
            Self::InsertPagesFrom { .. } => true,
            Self::RotatePages { .. }
            | Self::DeletePages { .. }
            | Self::MovePages { .. }
            | Self::InsertBlankPage { .. }
            | Self::SetInfo { .. }
            | Self::AddTextMarkup { .. }
            | Self::AddNote { .. }
            | Self::DeleteAnnotation { .. }
            | Self::DeleteAnnotations { .. }
            | Self::SetAnnotationContents { .. }
            | Self::AddInk { .. }
            | Self::AddSignature { .. }
            | Self::AddTextBox { .. }
            | Self::AddShape { .. }
            | Self::AddLine { .. }
            | Self::MoveAnnotation { .. }
            | Self::SetFieldValue { .. } => false,
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
            | Self::InsertPagesFrom { .. }
            | Self::DeleteAnnotation { .. }
            | Self::DeleteAnnotations { .. }
            | Self::SetAnnotationContents { .. }
            | Self::SetFieldValue { .. } => false,
            // A move's distance as shown is turned with the page into the file's space.
            Self::AddTextMarkup { .. }
            | Self::AddNote { .. }
            | Self::AddInk { .. }
            | Self::AddSignature { .. }
            | Self::AddTextBox { .. }
            | Self::AddShape { .. }
            | Self::AddLine { .. }
            | Self::MoveAnnotation { .. } => true,
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

/// Whether `value` is a view-space coordinate or distance the bridge converts: finite and within
/// `MAX_VIEW_COORD` of 0.
fn coordinate(value: f64) -> bool {
    value.is_finite() && value.abs() <= MAX_VIEW_COORD
}

/// Whether both of `p`'s coordinates are ones the bridge converts.
fn in_reach(p: Point) -> bool {
    coordinate(p.x) && coordinate(p.y)
}

/// Whether `rect`'s position, size and far edges are all ones the bridge converts.
fn rect_in_reach(rect: &Rect) -> bool {
    [
        rect.x,
        rect.y,
        rect.width,
        rect.height,
        rect.x + rect.width,
        rect.y + rect.height,
    ]
    .into_iter()
    .all(coordinate)
}

/// `rect`, once it is known to be a box with an area: within reach, and wider and taller than
/// nothing.
fn area(rect: &Rect) -> Result<&Rect, EditError> {
    if rect_in_reach(rect) && rect.width > 0.0 && rect.height > 0.0 {
        Ok(rect)
    } else {
        Err(invalid(format!("{rect:?} is not an area of the page")))
    }
}

/// `rect`, once it is known to be a box that can be drawn: within reach, and at least a point wide
/// and tall.
fn drawn_box(rect: &Rect) -> Result<&Rect, EditError> {
    if rect_in_reach(rect) && rect.width >= MIN_SIDE_PT && rect.height >= MIN_SIDE_PT {
        Ok(rect)
    } else {
        Err(invalid(format!(
            "{rect:?} is not a box at least {MIN_SIDE_PT} point wide and tall"
        )))
    }
}

/// `text`, once it is known to have at most `MAX_TEXT_CHARS` characters; `what` says whose text it
/// is in the error. Counting stops one past the cap, so a huge text costs no more than a long one.
fn capped<'a>(text: &'a str, what: &str) -> Result<&'a str, EditError> {
    if text.chars().nth(MAX_TEXT_CHARS).is_some() {
        Err(invalid(format!(
            "{what} has at most {MAX_TEXT_CHARS} characters"
        )))
    } else {
        Ok(text)
    }
}

/// A drawn line's width, once it is known to be one a line can have.
fn line_width(width: f64) -> Result<f64, EditError> {
    if width.is_finite() && LINE_WIDTHS.contains(&width) {
        Ok(width)
    } else {
        Err(invalid(format!(
            "a line is {} through {} points wide, not {width}",
            LINE_WIDTHS.start(),
            LINE_WIDTHS.end()
        )))
    }
}

/// A drawing's strokes in the page's user space, once they are known to be a drawing: at most
/// `MAX_STROKES` strokes of at most `MAX_STROKE_POINTS` points, at most `MAX_DRAWING_POINTS` points
/// in all, every one within reach, and at least one stroke with a point. Empty strokes are left out.
fn strokes_to_user(
    page: &pdfcraft_render::PageInfo,
    strokes: &[Vec<Point>],
) -> Result<Vec<Vec<[f64; 2]>>, EditError> {
    if strokes.len() > MAX_STROKES {
        return Err(invalid(format!(
            "a drawing has at most {MAX_STROKES} strokes, not {}",
            strokes.len()
        )));
    }
    if let Some(long) = strokes.iter().find(|s| s.len() > MAX_STROKE_POINTS) {
        return Err(invalid(format!(
            "a stroke has at most {MAX_STROKE_POINTS} points, not {}",
            long.len()
        )));
    }
    // Each stroke is within its cap, so the sum cannot overflow.
    let total: usize = strokes.iter().map(Vec::len).sum();
    if total > MAX_DRAWING_POINTS {
        return Err(invalid(format!(
            "a drawing has at most {MAX_DRAWING_POINTS} points in all, not {total}"
        )));
    }
    if let Some(p) = strokes.iter().flatten().find(|p| !in_reach(**p)) {
        return Err(invalid(format!(
            "({}, {}) is not a point on the page",
            p.x, p.y
        )));
    }
    let user: Vec<Vec<[f64; 2]>> = strokes
        .iter()
        .filter(|s| !s.is_empty())
        .map(|s| s.iter().map(|p| geometry::to_user(page, *p)).collect())
        .collect();
    if user.is_empty() {
        return Err(invalid("the drawing has no points".to_owned()));
    }
    Ok(user)
}

/// The engine's edit adding a drawing of `shape` on `page`: lines in `color`, `width` points wide,
/// filled with `fill` (rectangles and ovals only), fully opaque, with no text.
fn drawing(
    page: u32,
    shape: pdfcraft_engine::Shape,
    color: RgbColor,
    fill: Option<RgbColor>,
    width: f64,
) -> Result<pdfcraft_engine::Edit, EditError> {
    let style = pdfcraft_engine::Style {
        color: rgb(color)?,
        opacity: 1.0,
        width,
        fill: fill.map(rgb).transpose()?,
    };
    added(page, shape, style, "")
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
/// fully opaque.
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
    added(page, shape, style, contents)
}

/// The engine's edit adding an annotation of `shape` on `page`, drawn in `style`. The author is
/// left empty: the apps keep no personal data.
fn added(
    page: u32,
    shape: pdfcraft_engine::Shape,
    style: pdfcraft_engine::Style,
    contents: &str,
) -> Result<pdfcraft_engine::Edit, EditError> {
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

    /// A one-page document, open in its own session, for edits to be converted against.
    fn one_page() -> (pdfcraft_engine::Session, pdfcraft_engine::DocId) {
        let mut session = pdfcraft_engine::Session::new();
        let bytes = session.create_from_text("fixture", "x").unwrap();
        let id = session.open("fixture.pdf", None, bytes, None).unwrap();
        (session, id)
    }

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
        let (session, id) = one_page();
        let doc = session.get(id).unwrap();
        let ok = Edit::RotatePages {
            pages: vec![0, 2],
            degrees: -270,
        };
        assert_eq!(
            ok.to_engine(doc).unwrap(),
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
            assert!(matches!(bad.to_engine(doc), Err(EditError::Invalid { .. })));
        }
        for side in [0.0, -1.0, f64::NAN, f64::INFINITY, 14_400.5] {
            let bad = Edit::InsertBlankPage {
                at: 0,
                width_pt: side,
                height_pt: 100.0,
            };
            assert!(matches!(bad.to_engine(doc), Err(EditError::Invalid { .. })));
        }
        let largest = Edit::InsertBlankPage {
            at: 1,
            width_pt: 14_400.0,
            height_pt: 1.0,
        };
        assert!(largest.to_engine(doc).is_ok());
    }
}
