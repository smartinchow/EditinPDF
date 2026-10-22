//! The document's comments (annotations), as the apps list and address them.

use std::collections::{HashMap, HashSet};

use pdfcraft_annot::Rgb;
use pdfcraft_cos::{Dict, ObjRef, Object};

use crate::geometry;
use crate::{EditError, Rect, RgbColor};

/// The annotation flag that locks an annotation (ISO 32000-1, table 165, bit 8).
const LOCKED_FLAG: i64 = 128;

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
    /// Whether it marks text: a highlight, underline, strikethrough or squiggly underline, which
    /// cover the text of their quadrilaterals (`/QuadPoints`).
    pub(crate) fn is_text_markup(&self) -> bool {
        matches!(
            self,
            Self::Highlight | Self::Underline | Self::StrikeOut | Self::Squiggly
        )
    }

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
    /// When it was last changed, as the engine reads the file's PDF date (`D:…`): `YYYY-MM-DD HH:MM`
    /// with the time zone left out, or the file's text as it is when it is not a date the engine
    /// reads. `PdfDocument::annotation_dates` gives the dates as the file writes them, with their time
    /// zones, on request (reading them costs a read of the file). Text from the file: parse it as
    /// untrusted.
    pub modified: Option<String>,
    /// For a text box, the colour of its text (as its `/DA` gives it); for any other kind, the
    /// colour it is drawn in.
    pub color: Option<RgbColor>,
    /// The file forbids moving, changing or deleting it.
    pub locked: bool,
    /// A text box's text size, in points, as the engine draws it (its `/DA`'s `Tf`, or 12 when that
    /// gives none). None for every other kind.
    pub font_size: Option<f64>,
    /// A text box's background (its `/C`); none when it has none, and for every other kind.
    pub fill: Option<RgbColor>,
    /// How wide a text box's border is drawn, in points (its `/BS` `/W`, or its `/Border`; 0 for no
    /// border). None for every other kind.
    pub border_width: Option<f64>,
    /// A text box whose text size and background `RestyleTextBox` does not change, only its colour
    /// and border: adding it again would lose something (its replies, or rich text that is all its
    /// text), or it is a callout or typed text, which a plain box would replace. False for every other
    /// kind. (On a page shown turned, every text box keeps its size and background too.)
    pub restyle_in_place_only: bool,
    /// For a highlight, underline, strikethrough or squiggly underline, the boxes of the text it
    /// marks, one for each of its quadrilaterals (`/QuadPoints`), in the file's order: each the
    /// view-space box that holds its four corners, finite and within the same reach as `rect`. At
    /// most `MAX_LISTED_QUADS` for one mark, and `MAX_LISTED_QUADS_IN_ALL` for the whole list (the
    /// marks listed after that many have none). Empty for every other kind, and for a mark whose
    /// file gives none.
    #[uniffi(default = [])]
    pub quads: Vec<Rect>,
}

/// The comments of the document the engine read, page by page and top to bottom within a page.
/// Replies to other comments are left out: they belong to the comment they answer.
pub(crate) fn list(info: &pdfcraft_render::DocInfo) -> Vec<AnnotationInfo> {
    // How many more quads the list may carry, over all its marks.
    let mut quads_left = MAX_LISTED_QUADS_IN_ALL;
    let mut list: Vec<AnnotationInfo> = info
        .annotations
        .iter()
        .filter(|a| a.in_reply_to.is_none())
        .filter_map(|a| {
            let page = info.pages.get(a.page)?;
            let kind = AnnotationKind::from_subtype(&a.subtype);
            let quads = if kind.is_text_markup() {
                listed_quads(page, &a.quads, &mut quads_left)
            } else {
                Vec::new()
            };
            Some(AnnotationInfo {
                page: u32::try_from(a.page).ok()?,
                index: u32::try_from(a.index).ok()?,
                kind,
                rect: finite_rect(geometry::rect_to_view(page, a.rect)),
                contents: a.contents.clone(),
                author: a.author.clone(),
                modified: a.modified.clone(),
                color: a.color.map(|[red, green, blue]| RgbColor {
                    red: f64::from(red),
                    green: f64::from(green),
                    blue: f64::from(blue),
                }),
                locked: a.locked,
                // Filled in for text boxes, from the file, by `with_text_box_looks`.
                font_size: None,
                fill: None,
                border_width: None,
                restyle_in_place_only: false,
                quads,
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

/// The farthest from a page's origin, in points, a box the list gives may reach: a file's box past it
/// (or one that is not a number, as a single-precision box from a huge `/Rect` can become) is held to
/// it, so the apps are never handed an infinite or undefined box.
const MAX_LISTED_COORD: f64 = 1.0e6;

/// The most quads listed for one mark: as many boxes as one mark the apps add may cover
/// (`edit::MAX_MARKUP_RECTS`), which is far more lines than a page has.
pub(crate) const MAX_LISTED_QUADS: usize = crate::edit::MAX_MARKUP_RECTS;

/// The most quads listed for all the marks of a document together: what a hostile file can make the
/// list carry across the bridge is bounded, whatever number of marks it has.
pub(crate) const MAX_LISTED_QUADS_IN_ALL: usize = 100_000;

/// The view-space boxes of a mark's `quads` (each 8 numbers of user space, as the engine read them)
/// on `page`: at most `MAX_LISTED_QUADS`, and no more than `left`, which goes down by as many.
fn listed_quads(
    page: &pdfcraft_render::PageInfo,
    quads: &[[f32; 8]],
    left: &mut usize,
) -> Vec<Rect> {
    let take = quads.len().min(MAX_LISTED_QUADS).min(*left);
    *left = left.saturating_sub(take);
    quads
        .iter()
        .take(take)
        .map(|quad| quad_box(page, quad))
        .collect()
}

/// The view-space box that holds the four corners of `quad` (user space: x, y of each), with every
/// number finite and within `MAX_LISTED_COORD` (`finite_rect`). Its corners are held to the reach
/// before they are compared, so a corner that is not a number, or is infinite, cannot make the box so.
fn quad_box(page: &pdfcraft_render::PageInfo, quad: &[f32; 8]) -> Rect {
    let [x1, y1, x2, y2, x3, y3, x4, y4] = *quad;
    let corners = [(x1, y1), (x2, y2), (x3, y3), (x4, y4)].map(|(x, y)| {
        let p = geometry::to_view(page, [f64::from(x), f64::from(y)]);
        (held(p.x), held(p.y))
    });
    let (mut left, mut top) = corners[0];
    let (mut right, mut bottom) = corners[0];
    for (x, y) in corners {
        left = left.min(x);
        right = right.max(x);
        top = top.min(y);
        bottom = bottom.max(y);
    }
    finite_rect(Rect {
        x: left,
        y: top,
        width: right - left,
        height: bottom - top,
    })
}

/// `n` if it is finite, held to within `MAX_LISTED_COORD`; 0 if it is not a number or infinite.
fn held(n: f64) -> f64 {
    if n.is_finite() {
        n.clamp(-MAX_LISTED_COORD, MAX_LISTED_COORD)
    } else {
        0.0
    }
}

/// `rect` with every number finite and within `MAX_LISTED_COORD`: one that is not a number is 0, and
/// one past the reach is held to it.
fn finite_rect(rect: Rect) -> Rect {
    Rect {
        x: held(rect.x),
        y: held(rect.y),
        width: held(rect.width).max(0.0),
        height: held(rect.height).max(0.0),
    }
}

/// The engine's change that deletes the comments at `indices` (places in the 0-based `page`'s
/// `/Annots`, in any order, each given at least once) in the document as it is, `doc`, each with its
/// pop-up and its replies, and nothing else: one batch of the engine's deletes, so one undo step.
///
/// The engine deletes a comment by its place in the list as the list is when that delete runs, and
/// takes out with it its pop-up and its replies (and theirs), wherever they are listed
/// (`pdfcraft_annot::delete_annotation`). One delete can therefore move comments listed before its
/// place as well as after it, and no order of deletes by the places of the list before the step is
/// sure to address the comments meant. So each comment is followed as the object it is: the deletes
/// are worked out one after another on a copy of the list, which each changes as the engine will
/// change the list, and each goes at the place its comment has by then. A comment that an earlier
/// delete takes out with its own is not deleted again.
///
/// `Invalid` when a place is past the end of the list, or the file locks one of the comments (as the
/// engine refuses to delete a locked one, all of them); the document's own refusal when it cannot be
/// changed, or its security settings forbid changing comments.
pub(crate) fn deletes(
    doc: &pdfcraft_engine::Document,
    page: usize,
    indices: &[u32],
) -> Result<pdfcraft_engine::Edit, EditError> {
    comments_may_change(doc)?;
    let cos = working_file(doc)?;
    let list = page_annots(&cos, page_object(&cos, page)?);
    let mut targets = indices
        .iter()
        .map(|&index| {
            usize::try_from(index)
                .ok()
                .filter(|&place| place < list.len())
                .ok_or_else(|| EditError::Invalid {
                    message: format!("comment {index} does not exist"),
                })
        })
        .collect::<Result<Vec<usize>, _>>()?;
    targets.sort_unstable();
    targets.dedup();
    if let Some(locked) = targets
        .iter()
        .find(|&&place| list.get(place).is_some_and(|entry| is_locked(&cos, entry)))
    {
        return Err(EditError::Invalid {
            message: format!("comment {locked} is locked"),
        });
    }

    let mut graph = Graph {
        cos: &cos,
        links: HashMap::new(),
    };
    let mut entries: Vec<Entry> = list
        .iter()
        .enumerate()
        .map(|(place, entry)| Entry {
            place,
            object: entry.as_ref(),
        })
        .collect();
    let mut edits = Vec::new();
    for target in &targets {
        // Gone already: an earlier delete took it out with its own comment.
        let Some(at) = entries.iter().position(|entry| entry.place == *target) else {
            continue;
        };
        let target_object = entries.get(at).and_then(|entry| entry.object);
        let doomed = graph.doomed(&entries, target_object);
        edits.push(pdfcraft_engine::Edit::DeleteAnnotation { page, index: at });
        entries = entries
            .into_iter()
            .enumerate()
            .filter(|(i, entry)| *i != at && !entry.object.is_some_and(|r| doomed.contains(&r)))
            .map(|(_, entry)| entry)
            .collect();
    }
    let label = if targets.len() == 1 {
        "Delete comment"
    } else {
        "Delete comments"
    };
    Ok(pdfcraft_engine::Edit::Batch {
        label: label.to_owned(),
        edits,
    })
}

/// The opacity (`/CA`) of the comment at place `index` of the 0-based `page`'s `/Annots` in the
/// document as it is (`doc`), as the engine draws it: from 0 to 1 (a file's number outside that is
/// held to it), and 1 when the file gives none or one that is not a finite number. `Invalid` when the
/// page has no comment at that place; `Failed` when the file cannot be read again.
pub(crate) fn opacity_at(
    doc: &pdfcraft_engine::Document,
    page: usize,
    index: u32,
) -> Result<f64, EditError> {
    let cos = working_file(doc)?;
    let list = page_annots(&cos, page_object(&cos, page)?);
    let entry = usize::try_from(index)
        .ok()
        .and_then(|place| list.get(place))
        .ok_or_else(|| EditError::Invalid {
            message: format!("comment {index} does not exist"),
        })?;
    let object = cos.resolve(entry);
    let opacity = object
        .as_dict()
        .and_then(|d| d.get(b"CA"))
        .and_then(|ca| cos.resolve(ca).as_f64())
        .filter(|opacity| opacity.is_finite())
        .unwrap_or(1.0);
    Ok(opacity.clamp(0.0, 1.0))
}

/// `Ok` when the document's comments may be changed; otherwise the engine's own refusal: the document
/// cannot be changed, or its security settings forbid changing comments. Checked before the file is
/// read again for nothing.
fn comments_may_change(doc: &pdfcraft_engine::Document) -> Result<(), EditError> {
    if !doc.editable() {
        return Err(pdfcraft_engine::EditError::ReadOnly(
            doc.read_only_reason.clone().unwrap_or_default(),
        )
        .into());
    }
    if !doc.allows_annotation() {
        return Err(pdfcraft_engine::EditError::NotPermitted("comments").into());
    }
    Ok(())
}

/// The document's working file, read again by the object layer: the document as it is now, edits
/// included (the engine's own copy of its objects is not shared). Opening it reads only its
/// cross-reference data; objects are read as they are asked for.
fn working_file(doc: &pdfcraft_engine::Document) -> Result<pdfcraft_cos::Document, EditError> {
    pdfcraft_cos::Document::open_with_password(doc.bytes.clone(), doc.password.as_deref()).map_err(
        |err| EditError::Failed {
            message: format!("the document could not be read: {err}"),
        },
    )
}

/// The object of the 0-based page `page`, in the engine's own page order; `Invalid` when there is none.
fn page_object(cos: &pdfcraft_cos::Document, page: usize) -> Result<ObjRef, EditError> {
    pdfcraft_annot::page_refs(cos)
        .ok()
        .and_then(|pages| pages.get(page).copied())
        .ok_or_else(|| EditError::Invalid {
            message: format!("page {page} does not exist"),
        })
}

/// How a text box (`/FreeText`) is drawn: its text's size and colour, its background, and its
/// border's width. What `RestyleTextBox` asks for, and what the file says, read as the engine draws it
/// (`pdfcraft_annot::appearance`).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct TextBoxLook {
    pub(crate) font_size: f64,
    pub(crate) color: Rgb,
    pub(crate) fill: Option<Rgb>,
    pub(crate) border_width: f64,
}

impl TextBoxLook {
    /// The look of the text box `d`, an annotation dictionary of `cos`, as the engine draws it: its
    /// `/DA`'s colour and size (black and 12 points when it gives none), its `/C` as the background
    /// (gray, RGB or CMYK; none when it has none or one the engine does not read), and the width of
    /// its border: `/BS`'s `/W`, else the third number of `/Border`, else 1 point when either is
    /// there, and none when neither is. A number that is not finite counts as none.
    fn of(cos: &pdfcraft_cos::Document, d: &Dict) -> Self {
        let (color, font_size) = pdfcraft_annot::appearance::parse_da(d);
        // At most four numbers are read of either array (a colour has at most four, a border's width
        // is its third): a longer one is not resolved element by element.
        let numbers = |object: Option<&Object>| -> Option<Vec<f64>> { numbers_of(cos, object?, 4) };
        let fill = numbers(d.get(b"C")).and_then(|c| match c.as_slice() {
            [g] => Some([*g; 3]),
            [r, g, b] => Some([*r, *g, *b]),
            [c, m, y, k] => Some([
                (1.0 - c) * (1.0 - k),
                (1.0 - m) * (1.0 - k),
                (1.0 - y) * (1.0 - k),
            ]),
            _ => None,
        });
        let style_width = d.get(b"BS").and_then(|bs| {
            let bs = cos.resolve(bs);
            bs.as_dict()
                .and_then(|bs| bs.get(b"W"))
                .and_then(|w| cos.resolve(w).as_f64())
        });
        let border_width = match (style_width, numbers(d.get(b"Border"))) {
            (Some(w), _) => w,
            (None, Some(border)) if border.len() >= 3 => border.get(2).copied().unwrap_or(1.0),
            _ if d.get(b"BS").is_some() || d.get(b"Border").is_some() => 1.0,
            _ => 0.0,
        };
        Self {
            // The file's numbers are not trusted: each is held to a range (the engine's own for the
            // size, 0 through 1 for a colour, at most `MAX_BORDER` for a border) before any
            // arithmetic is done with it.
            font_size: if font_size.is_finite() && font_size > 0.0 {
                font_size.min(400.0)
            } else {
                12.0
            },
            color: color.map(|x| {
                if x.is_finite() {
                    x.clamp(0.0, 1.0)
                } else {
                    0.0
                }
            }),
            fill: fill.map(|c| c.map(|x| x.clamp(0.0, 1.0))),
            border_width: if border_width.is_finite() {
                border_width.clamp(0.0, MAX_BORDER)
            } else {
                0.0
            },
        }
    }
}

/// How far apart two of a text box's numbers (a colour's components, in 0 through 1; a size or a
/// border, in points) may be and still be the same, as a file keeps them: under 0.004, about a 255th,
/// what an 8-bit colour can tell apart and what the engine's single precision and rounding blur.
/// `look_tolerance` hands it to the apps, which compare looks by the same rule, so a look they take
/// for a change is one the bridge takes for a change too.
pub(crate) const LOOK_TOLERANCE: f64 = 0.004;

/// Whether two of a file's numbers are the same to within what it keeps of them (`LOOK_TOLERANCE`).
fn close(a: f64, b: f64) -> bool {
    (a - b).abs() < LOOK_TOLERANCE
}

/// Whether two colours are the same to within what a file keeps of them.
fn same_color(a: Rgb, b: Rgb) -> bool {
    a.iter().zip(b).all(|(a, b)| close(*a, b))
}

/// Whether two backgrounds are the same: none both, or the same colour.
fn same_fill(a: Option<Rgb>, b: Option<Rgb>) -> bool {
    match (a, b) {
        (None, None) => true,
        (Some(a), Some(b)) => same_color(a, b),
        _ => false,
    }
}

/// The numbers of the array `object` is (resolved), each finite; none when it is not an array of
/// at most `most` numbers. Its elements are resolved only once its length is known to be within that.
fn numbers_of(cos: &pdfcraft_cos::Document, object: &Object, most: usize) -> Option<Vec<f64>> {
    let array = cos.resolve(object);
    let items = array.as_array().filter(|items| items.len() <= most)?;
    items
        .iter()
        .map(|o| cos.resolve(o).as_f64().filter(|n| n.is_finite()))
        .collect()
}

/// What `RestyleTextBox` asks for: a text size (none to keep the box's), the text's colour, the
/// background, and a border width (none to keep the box's).
#[derive(Clone, Copy, Debug, PartialEq)]
pub(crate) struct TextBoxRestyle {
    pub(crate) font_size: Option<f64>,
    pub(crate) color: Rgb,
    pub(crate) fill: Option<Rgb>,
    pub(crate) border_width: Option<f64>,
}

/// The objects some entry of a page's `/Annots` (`entries`) replies to (`/IRT`): read in one pass
/// over the list, so that asking whether a comment has replies is a lookup, not another pass.
fn replied_to(cos: &pdfcraft_cos::Document, entries: &[Object]) -> HashSet<ObjRef> {
    entries
        .iter()
        .filter_map(|entry| {
            cos.resolve(entry)
                .as_dict()
                .and_then(|d| d.reference(b"IRT"))
        })
        .collect()
}

/// Why a text box can't be added again with a new size or background (`restyle_text_box`), when it
/// can't: it is a callout or typed text, it has replies (the delete would take them out), or its
/// text is all in rich text (`/RC` with no `/Contents`), which a plain box would lose. `d` is the
/// text box `entry` (an entry of its page's `/Annots`) is; `replied` the objects of that page that
/// have replies (`replied_to`).
fn re_add_refusal(
    cos: &pdfcraft_cos::Document,
    replied: &HashSet<ObjRef>,
    entry: &Object,
    d: &Dict,
) -> Option<&'static str> {
    if d.get(b"CL").is_some() || d.name(b"IT").is_some_and(|it| it != b"FreeText") {
        return Some("a callout or typed text keeps its text size and background");
    }
    let contents_empty = d
        .get(b"Contents")
        .map(|o| cos.resolve(o))
        .and_then(|o| o.as_string().map(|s| s.to_text().trim().is_empty()))
        .unwrap_or(true);
    if d.get(b"RC").is_some() && contents_empty {
        return Some("a text box whose text is all rich text keeps its text size and background");
    }
    if entry
        .as_ref()
        .is_some_and(|object| replied.contains(&object))
    {
        return Some("a text box with replies keeps its text size and background");
    }
    None
}

/// The most characters of a file's date passed on: a PDF date has at most 23.
const MAX_DATE_CHARS: usize = 64;
/// The most bytes of a file's date string decoded: `MAX_DATE_CHARS` in UTF-16 and its byte order
/// mark. A longer string is not decoded at all.
const MAX_DATE_BYTES: usize = 2 + 2 * MAX_DATE_CHARS;

/// When one comment was last changed, as its file writes it (`PdfDocument::annotation_dates`).
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct AnnotationDate {
    /// The comment's page and place, as `AnnotationInfo` gives them at the same revision.
    pub page: u32,
    pub index: u32,
    /// Its `/M`, else its `/CreationDate`, as the file writes it: a PDF date (`D:YYYYMMDDHHmmSS` and
    /// its offset from UTC, `Z`, `+HH'mm'`, `-HH'mm'`), at most 64 characters. Text from the file:
    /// parse it as untrusted.
    pub raw: String,
}

/// The date the annotation dictionary `d` of `cos` writes: its `/M`, else its `/CreationDate`, when
/// that is a string of at most `MAX_DATE_BYTES` bytes (checked before it is decoded) and
/// `MAX_DATE_CHARS` characters, not blank.
fn raw_date(cos: &pdfcraft_cos::Document, d: &Dict) -> Option<String> {
    [b"M".as_slice(), b"CreationDate".as_slice()]
        .into_iter()
        .find_map(|key| {
            let object = cos.resolve(d.get(key)?);
            let string = object.as_string()?;
            (string.bytes.len() <= MAX_DATE_BYTES).then(|| string.to_text())
        })
        .filter(|date| !date.trim().is_empty() && date.chars().count() <= MAX_DATE_CHARS)
}

/// The dates the file writes for the comments of `list` (as `list` gives them, read from `doc`, the
/// document as it is), in `list`'s order; a comment with none, or one the file no longer has at its
/// place, is left out, and none at all when the file cannot be read again. One read of each page's
/// `/Annots` and of each comment's dictionary. Reads only, and never panics on a file's numbers.
pub(crate) fn dates(
    doc: &pdfcraft_engine::Document,
    list: &[AnnotationInfo],
) -> Vec<AnnotationDate> {
    if list.is_empty() {
        return Vec::new();
    }
    let Ok(cos) = working_file(doc) else {
        return Vec::new();
    };
    let Ok(pages) = pdfcraft_annot::page_refs(&cos) else {
        return Vec::new();
    };
    let mut lists: HashMap<u32, Vec<Object>> = HashMap::new();
    list.iter()
        .filter_map(|info| {
            let entries = lists.entry(info.page).or_insert_with(|| {
                usize::try_from(info.page)
                    .ok()
                    .and_then(|page| pages.get(page))
                    .map(|page| page_annots(&cos, *page))
                    .unwrap_or_default()
            });
            let entry = entries.get(usize::try_from(info.index).ok()?)?;
            let object = cos.resolve(entry);
            let raw = raw_date(&cos, object.as_dict()?)?;
            Some(AnnotationDate {
                page: info.page,
                index: info.index,
                raw,
            })
        })
        .collect()
}

fn rgb_color([red, green, blue]: Rgb) -> RgbColor {
    RgbColor { red, green, blue }
}

/// Fills in, from the document as it is (`doc`, its working file read again), what the engine's list
/// does not give of every text box: its size, background, border width and whether it can only be
/// restyled in place, and its colour when the engine's list gave none (a gray `/DA`, or none at all:
/// the engine draws black). Nothing is read when `list` has no text box. A text box whose page or
/// place the file no longer has is left as it is; so is every one when the file cannot be read
/// again. Reads only, and never panics on a file's numbers.
pub(crate) fn with_text_box_looks(doc: &pdfcraft_engine::Document, list: &mut [AnnotationInfo]) {
    if !list.iter().any(|a| a.kind == AnnotationKind::TextBox) {
        return;
    }
    let Ok(cos) = working_file(doc) else {
        return;
    };
    let Ok(pages) = pdfcraft_annot::page_refs(&cos) else {
        return;
    };
    let mut lists: HashMap<u32, Vec<Object>> = HashMap::new();
    // For each page with a text box: what its comments reply to, read once (`replied_to`).
    let mut replies: HashMap<u32, HashSet<ObjRef>> = HashMap::new();
    for info in list
        .iter_mut()
        .filter(|a| a.kind == AnnotationKind::TextBox)
    {
        let entries = lists.entry(info.page).or_insert_with(|| {
            usize::try_from(info.page)
                .ok()
                .and_then(|page| pages.get(page))
                .map(|page| page_annots(&cos, *page))
                .unwrap_or_default()
        });
        let Some(entry) = usize::try_from(info.index)
            .ok()
            .and_then(|place| entries.get(place))
        else {
            continue;
        };
        let object = cos.resolve(entry);
        let Some(d) = object.as_dict() else {
            continue;
        };
        if d.name(b"Subtype") != Some(b"FreeText") {
            continue;
        }
        let look = TextBoxLook::of(&cos, d);
        info.font_size = Some(look.font_size);
        info.fill = look.fill.map(rgb_color);
        info.border_width = Some(look.border_width);
        let replied = replies
            .entry(info.page)
            .or_insert_with(|| replied_to(&cos, entries));
        info.restyle_in_place_only = re_add_refusal(&cos, replied, entry, d).is_some();
        if info.color.is_none() {
            info.color = Some(rgb_color(look.color));
        }
    }
}

/// The widest border a text box is reported with, in points: a file's wider one is reported as this.
const MAX_BORDER: f64 = 144.0;

/// The farthest from the origin, in points, a text box's box may be, as the file gives it or once it
/// is restyled: well past any page, and small enough that the arithmetic on it stays finite.
const MAX_USER_COORD: f64 = 1.0e6;

/// What a text box is called in the change that formats it, for the Edit menu.
const RESTYLE_LABEL: &str = "Format text box";

/// The engine's change that gives the text box at place `index` of the 0-based `page` (`info`, as
/// the document has it before the change, `doc`) what `asked` asks for: one batch, so one undo step.
/// A size or a border not asked for is the box's own, kept as the file has it.
///
/// - The same text size and background: the engine's `StyleAnnotation`, in place, with the colour
///   (which the engine writes into `/DA`, keeping the size) and the border width, when they change.
/// - Otherwise the engine has no change that does it, so the text box is deleted and added again:
///   the same text and author, its top-left corner where it was, as wide as keeps its lines where
///   they broke at the new size (no further than the page's right edge, unless it was already past
///   it), and as tall as its text then needs, at least as tall as it was in proportion. The box added
///   again goes at the end of the page's list, so it moves the places of the comments after it (as
///   a delete does), and it is drawn over the others. What it does not keep: its name (`/NM`),
///   creation date, pop-up, opacity, alignment and rich text, and any other entry the file gave it. This is
///   refused on a page shown turned (the engine would set its text upright in the file), and where
///   it would lose more (`re_add_refusal`: a callout or typed text, a box with replies, one whose
///   text is all rich text).
///
/// `Invalid` when the page has no comment at `index`, it is not a text box, the file locks it, or
/// nothing would change (so no empty step is ever made); the document's own refusal when it cannot
/// be changed, or its security settings forbid changing comments.
pub(crate) fn restyle_text_box(
    doc: &pdfcraft_engine::Document,
    info: &pdfcraft_render::PageInfo,
    page: usize,
    index: u32,
    asked: TextBoxRestyle,
) -> Result<pdfcraft_engine::Edit, EditError> {
    comments_may_change(doc)?;
    let cos = working_file(doc)?;
    let list = page_annots(&cos, page_object(&cos, page)?);
    let invalid = |message: String| EditError::Invalid { message };
    let (place, entry) = usize::try_from(index)
        .ok()
        .and_then(|place| list.get(place).map(|entry| (place, entry)))
        .ok_or_else(|| invalid(format!("comment {index} does not exist")))?;
    let object = cos.resolve(entry);
    let d = object
        .as_dict()
        .filter(|d| d.name(b"Subtype") == Some(b"FreeText"))
        .ok_or_else(|| invalid(format!("comment {index} is not a text box")))?;
    if is_locked(&cos, entry) {
        return Err(invalid(format!("comment {index} is locked")));
    }
    let now = TextBoxLook::of(&cos, d);
    let look = TextBoxLook {
        font_size: asked.font_size.unwrap_or(now.font_size),
        color: asked.color,
        fill: asked.fill,
        border_width: asked.border_width.unwrap_or(now.border_width),
    };
    let size_changes = !close(look.font_size, now.font_size);
    let fill_changes = !same_fill(look.fill, now.fill);
    let color_changes = !same_color(look.color, now.color);
    let border_changes = !close(look.border_width, now.border_width);
    if !(size_changes || fill_changes || color_changes || border_changes) {
        return Err(invalid(format!("text box {index} already looks like that")));
    }
    if !(size_changes || fill_changes) {
        return Ok(pdfcraft_engine::Edit::Batch {
            label: RESTYLE_LABEL.to_owned(),
            edits: vec![pdfcraft_engine::Edit::StyleAnnotation {
                page,
                index: place,
                color: color_changes.then_some(look.color),
                opacity: None,
                width: border_changes.then_some(look.border_width),
                endings: None,
            }],
        });
    }
    if !info.rotation.is_multiple_of(360) {
        return Err(invalid(
            "a text box on a page shown turned keeps its text size and background".to_owned(),
        ));
    }
    if let Some(why) = re_add_refusal(&cos, &replied_to(&cos, &list), entry, d) {
        return Err(invalid(why.to_owned()));
    }
    let text = |key: &[u8]| {
        d.get(key)
            .map(|o| cos.resolve(o))
            .and_then(|o| o.as_string().map(pdfcraft_cos::PdfString::to_text))
            .unwrap_or_default()
    };
    let contents = text(b"Contents");
    let author = text(b"T");
    let rect = d
        .get(b"Rect")
        .and_then(|o| numbers_of(&cos, o, 4))
        .and_then(|r| <[f64; 4]>::try_from(r).ok())
        .filter(|r| r.iter().all(|n| n.abs() <= MAX_USER_COORD))
        .ok_or_else(|| invalid(format!("text box {index} has no box on its page")))?;
    let style = pdfcraft_engine::Style {
        color: look.color,
        opacity: 1.0,
        width: look.border_width,
        fill: look.fill,
    };
    let rect = restyled_box(rect, &now, &look, &contents, f64::from(info.crop[2]));
    if !rect
        .iter()
        .all(|n| n.is_finite() && n.abs() <= MAX_USER_COORD)
    {
        return Err(invalid(format!(
            "text box {index} would not fit on its page at that size"
        )));
    }
    let shape = pdfcraft_engine::Shape::TextBox {
        rect,
        font_size: look.font_size,
    };
    Ok(pdfcraft_engine::Edit::Batch {
        label: RESTYLE_LABEL.to_owned(),
        edits: vec![
            pdfcraft_engine::Edit::DeleteAnnotation { page, index: place },
            pdfcraft_engine::Edit::AddAnnotation(pdfcraft_engine::NewAnnotation {
                page,
                shape,
                style,
                contents,
                author,
            }),
        ],
    })
}

/// The box (user space, `[x0, y0, x1, y1]`) a text box in `rect`, drawn as `now`, has once it shows
/// `text` as `look`: its top-left corner where it was; the room across for its text scaled with the
/// text size, so its lines break where they did (Helvetica's widths grow with the size), with the
/// new border's margins, no further right than `page_right` (the page's right edge) unless the box
/// already went past it; and as tall as the engine's own fitting makes a box for its text at that
/// width (`pdfcraft_annot`'s `fitted_box`), or as its old height scaled the same way, whichever is
/// taller. Never under a point either way.
fn restyled_box(
    rect: [f64; 4],
    now: &TextBoxLook,
    look: &TextBoxLook,
    text: &str,
    page_right: f64,
) -> [f64; 4] {
    let (x0, x1) = (rect[0].min(rect[2]), rect[0].max(rect[2]));
    let (y0, top) = (rect[1].min(rect[3]), rect[1].max(rect[3]));
    let ratio = look.font_size / now.font_size.max(1.0);
    let (old_pad, pad) = (2.0 + now.border_width, 2.0 + look.border_width);
    let across = ((x1 - x0 - 2.0 * old_pad).max(1.0) * ratio).max(1.0);
    let right = (x0 + across + 2.0 * pad).min(page_right.max(x1));
    let width = (right - x0).max(1.0);
    let lines =
        pdfcraft_annot::appearance::wrap(text, look.font_size, (width - 2.0 * pad).max(1.0))
            .len()
            .max(1);
    #[allow(clippy::cast_precision_loss)]
    let fitted = lines as f64 * look.font_size * 1.2 + 2.0 * pad + 2.0;
    let scaled = (top - y0 - 2.0 * old_pad).max(0.0) * ratio + 2.0 * pad;
    let height = fitted.max(scaled).max(1.0);
    [x0, top - height, x0 + width, top]
}

/// The entries of the page `page`'s `/Annots` (references, or dictionaries written in the list), as
/// the engine reads them: none when it has none.
fn page_annots(cos: &pdfcraft_cos::Document, page: ObjRef) -> Vec<Object> {
    let page = cos.get(page);
    let Some(list) = page.as_dict().and_then(|d| d.get(b"Annots")) else {
        return Vec::new();
    };
    cos.resolve(list).as_array().cloned().unwrap_or_default()
}

/// Whether the file locks the annotation `entry` is (the Locked flag of its `/F`).
fn is_locked(cos: &pdfcraft_cos::Document, entry: &Object) -> bool {
    cos.resolve(entry).as_dict().is_some_and(|d| {
        d.get(b"F")
            .and_then(|flags| cos.resolve(flags).as_int())
            .is_some_and(|flags| flags & LOCKED_FLAG != 0)
    })
}

/// An entry of a page's `/Annots`, as `deletes` follows it through the deletes: its place in the list
/// before them, and the object it is (none for a dictionary written in the list, which no other
/// entry can point at).
struct Entry {
    place: usize,
    object: Option<ObjRef>,
}

/// What an annotation points at that the engine's delete follows: the comment it replies to
/// (`/IRT`), the one it is the pop-up of (`/Parent`), and its own pop-up (`/Popup`).
#[derive(Clone, Copy, Default)]
struct Links {
    replies_to: Option<ObjRef>,
    parent: Option<ObjRef>,
    popup: Option<ObjRef>,
}

/// The objects of the file, read for their links once each.
struct Graph<'a> {
    cos: &'a pdfcraft_cos::Document,
    links: HashMap<ObjRef, Links>,
}

impl Graph<'_> {
    fn links(&mut self, object: ObjRef) -> Links {
        let cos = self.cos;
        *self.links.entry(object).or_insert_with(|| {
            let read = cos.get(object);
            read.as_dict().map_or_else(Links::default, |d| Links {
                replies_to: d.reference(b"IRT"),
                parent: d.reference(b"Parent"),
                popup: d.reference(b"Popup"),
            })
        })
    }

    /// What the engine's delete of `target`, the object of an entry of `entries` (none for one written
    /// in the list), takes out of the list besides the entry itself: `target`; then, until nothing
    /// more is added, every entry that replies to or is the pop-up of one taken (`/IRT`, `/Parent`),
    /// and the pop-up of every one taken (`/Popup`), listed or not. Every entry whose object is one of
    /// these goes.
    fn doomed(&mut self, entries: &[Entry], target: Option<ObjRef>) -> HashSet<ObjRef> {
        let mut doomed: HashSet<ObjRef> = target.into_iter().collect();
        loop {
            let before = doomed.len();
            for object in entries.iter().filter_map(|entry| entry.object) {
                if doomed.contains(&object) {
                    continue;
                }
                let links = self.links(object);
                let points_at_one = |to: Option<ObjRef>| to.is_some_and(|to| doomed.contains(&to));
                if points_at_one(links.replies_to) || points_at_one(links.parent) {
                    doomed.insert(object);
                }
            }
            let mut popups_of: Vec<ObjRef> = doomed.iter().copied().collect();
            while let Some(object) = popups_of.pop() {
                if let Some(popup) = self.links(object).popup
                    && doomed.insert(popup)
                {
                    popups_of.push(popup);
                }
            }
            if doomed.len() == before {
                return doomed;
            }
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    fn letter() -> pdfcraft_render::PageInfo {
        pdfcraft_render::PageInfo {
            width: 612.0,
            height: 792.0,
            label: String::new(),
            crop: [0.0, 0.0, 612.0, 792.0],
            rotation: 0,
        }
    }

    #[test]
    fn quads_stop_at_the_cap_for_all_the_marks() {
        let quad = [10.0, 700.0, 20.0, 700.0, 10.0, 690.0, 20.0, 690.0];
        let mut left = 3;
        assert_eq!(listed_quads(&letter(), &[quad; 2], &mut left).len(), 2);
        assert_eq!(left, 1);
        assert_eq!(listed_quads(&letter(), &[quad; 2], &mut left).len(), 1);
        assert_eq!(left, 0);
        assert!(listed_quads(&letter(), &[quad; 2], &mut left).is_empty());
        let mut plenty = usize::MAX;
        let many = vec![quad; MAX_LISTED_QUADS + 1];
        assert_eq!(
            listed_quads(&letter(), &many, &mut plenty).len(),
            MAX_LISTED_QUADS
        );
    }

    #[test]
    fn a_quads_box_holds_its_corners_and_stays_finite() {
        let quad = [10.0, 700.0, 20.0, 700.0, 10.0, 690.0, 20.0, 690.0];
        let b = quad_box(&letter(), &quad);
        for (n, expected) in [(b.x, 10.0), (b.y, 92.0), (b.width, 10.0), (b.height, 10.0)] {
            assert!((n - expected).abs() < 0.01, "{b:?}");
        }
        for hostile in [
            [
                f32::INFINITY,
                0.0,
                f32::NEG_INFINITY,
                0.0,
                0.0,
                0.0,
                0.0,
                0.0,
            ],
            [f32::NAN; 8],
            [f32::MAX, -f32::MAX, -f32::MAX, f32::MAX, 0.0, 0.0, 0.0, 0.0],
        ] {
            let b = quad_box(&letter(), &hostile);
            for n in [b.x, b.y, b.width, b.height] {
                assert!(n.is_finite() && n.abs() <= MAX_LISTED_COORD, "{b:?}");
            }
            assert!(b.width >= 0.0 && b.height >= 0.0, "{b:?}");
        }
    }

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
