//! The document's comments (annotations), as the apps list and address them.

use std::collections::{HashMap, HashSet};

use pdfcraft_cos::{ObjRef, Object};

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
    // Refused here as the engine would refuse it, before the file is read again for nothing.
    if !doc.editable() {
        return Err(pdfcraft_engine::EditError::ReadOnly(
            doc.read_only_reason.clone().unwrap_or_default(),
        )
        .into());
    }
    if !doc.allows_annotation() {
        return Err(pdfcraft_engine::EditError::NotPermitted("comments").into());
    }
    // The working file is the document as it is now, edits included; the engine's own copy of its
    // objects is not shared. Opening it reads only its cross-reference data; objects are read as
    // they are asked for.
    let cos =
        pdfcraft_cos::Document::open_with_password(doc.bytes.clone(), doc.password.as_deref())
            .map_err(|err| EditError::Failed {
                message: format!("the document could not be read: {err}"),
            })?;
    // The page as the engine's delete finds it.
    let page_object = pdfcraft_annot::page_refs(&cos)
        .ok()
        .and_then(|pages| pages.get(page).copied())
        .ok_or_else(|| EditError::Invalid {
            message: format!("page {page} does not exist"),
        })?;
    let list = page_annots(&cos, page_object);
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
