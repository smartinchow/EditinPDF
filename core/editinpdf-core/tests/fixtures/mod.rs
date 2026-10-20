//! In-memory fixture documents for the bridge tests.
//!
//! Every document is built here, in memory, with the engine's own create / edit / save API (and one,
//! `one_line_doc`, written by hand), so the Rust tests need no binary files. This module is the
//! single place that knows how to make a PDF. The PDF files that the apps' own tests open are checked
//! in next to those tests; `fixtures_export.rs` writes them from the documents made here.
//!
//! Each integration-test crate compiles this module on its own and uses only some helpers, hence
//! the `dead_code` allowance; the clippy allowances mirror the ones the test files carry.
#![allow(dead_code, clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use std::sync::Arc;

use pdfcraft_engine::{
    Algorithm, BoxSpec, Changes, Edit, FieldProps, ImageResolution, Markup, NewAnnotation,
    NewField, NoteIcon, PageBox, Protection, Session, Shape, Style,
};

/// The fixtures' session clock. Fixed, so the plain fixtures' bytes (their `/ModDate`) are the same
/// on every run and one dumped to disk does not churn. (An encrypted one still differs: the engine
/// draws its encryption keys and salts from OS randomness.)
const FIXTURE_CLOCK: i64 = 1_700_000_000;

/// A 17x22 px, 8-bit grey PNG (74 bytes): a flat light-grey rectangle, no resolution chunk.
/// Written as a literal so the tests need no image encoder.
#[rustfmt::skip]
const GREY_PNG: [u8; 74] = [
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x16,
    0x08, 0x00, 0x00, 0x00, 0x00, 0x03, 0x03, 0x28, 0x9E, 0x00, 0x00, 0x00,
    0x11, 0x49, 0x44, 0x41, 0x54, 0x78, 0xDA, 0x63, 0xB8, 0x80, 0x0E, 0x18,
    0x46, 0x45, 0x06, 0x48, 0x04, 0x00, 0x16, 0x91, 0x2F, 0xF0, 0x8D, 0x6F,
    0xD8, 0x2A, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42,
    0x60, 0x82,
];

fn session() -> Session {
    Session::new().with_clock(|| FIXTURE_CLOCK)
}

/// Opens `bytes` in a fresh session, applies `edit`, and returns the saved (fully rewritten) result.
fn edited(bytes: Vec<u8>, edit: Edit) -> Vec<u8> {
    edited_all(bytes, vec![edit])
}

/// Opens `bytes` in a fresh session, applies `edits` in order, and returns the saved (fully
/// rewritten) result.
fn edited_all(bytes: Vec<u8>, edits: Vec<Edit>) -> Vec<u8> {
    let mut session = session();
    let id = session
        .open("fixture.pdf", None, Arc::new(bytes), None)
        .expect("the fixture opens");
    for edit in edits {
        session.apply(id, edit).expect("the edit applies");
    }
    session
        .save_full_bytes(id)
        .expect("the result saves")
        .to_vec()
}

/// A document with one page per entry, each page showing that text (Helvetica 11 pt, US Letter).
///
/// Each entry must fit on one page (about 47 short lines); the engine starts a new page at every
/// form feed, which is how the entries are separated.
pub fn text_doc(pages: &[&str]) -> Vec<u8> {
    assert!(!pages.is_empty(), "a text document needs at least one page");
    let bytes = session()
        .create_from_text("fixture", &pages.join("\u{c}"))
        .expect("text pages create")
        .to_vec();
    // Pin the contract: one page per entry, so a long entry can't silently add pages.
    let mut check = session();
    let id = check
        .open("fixture.pdf", None, Arc::new(bytes.clone()), None)
        .expect("the fixture opens");
    assert_eq!(
        check.get(id).expect("the fixture is open").info.pages.len(),
        pages.len(),
        "each entry must fit on one page"
    );
    bytes
}

/// `text_doc` protected with `password` as its open (user) password: AES-256, nothing else restricted.
pub fn encrypted_doc(pages: &[&str], password: &str) -> Vec<u8> {
    let protection = Protection {
        open_password: Some(password.to_owned()),
        ..Protection::default()
    };
    edited(text_doc(pages), Edit::Protect(protection))
}

/// `text_doc` protected at the given compatibility level with a different open (user) password and
/// permissions (owner) password. Either one opens it.
pub fn protected_doc(pages: &[&str], user: &str, owner: &str, algorithm: Algorithm) -> Vec<u8> {
    let protection = Protection {
        open_password: Some(user.to_owned()),
        permissions_password: Some(owner.to_owned()),
        algorithm,
        ..Protection::default()
    };
    edited(text_doc(pages), Edit::Protect(protection))
}

/// `text_doc` that opens without a password but whose permissions (owner) password, `owner`, is
/// needed for any change: its security settings allow no page changes, so its pages can't be copied
/// (assembled into another document) either.
pub fn restricted_doc(pages: &[&str], owner: &str) -> Vec<u8> {
    let protection = Protection {
        permissions_password: Some(owner.to_owned()),
        changes: Changes::None,
        ..Protection::default()
    };
    edited(text_doc(pages), Edit::Protect(protection))
}

/// A one-page document (US Letter on file) whose page has `/Rotate 90`, so it is shown landscape.
pub fn rotated_doc(text: &str) -> Vec<u8> {
    // Edits count pages from 0.
    edited(
        text_doc(&[text]),
        Edit::RotatePages {
            pages: vec![0],
            degrees: 90,
        },
    )
}

/// A one-page document whose page has `/Rotate 180`, so it is shown upside down.
pub fn upside_down_doc(text: &str) -> Vec<u8> {
    edited(
        text_doc(&[text]),
        Edit::RotatePages {
            pages: vec![0],
            degrees: 180,
        },
    )
}

/// A one-page document whose page has a crop box that does not start at the origin
/// (`[36 36 576 756]`) and `/Rotate 270`, so a view-space position is both shifted and turned.
pub fn cropped_rotated_doc(text: &str) -> Vec<u8> {
    let cropped = edited(
        text_doc(&[text]),
        Edit::SetPageBox {
            pages: vec![0],
            which: PageBox::Crop,
            spec: BoxSpec::Rect([36.0, 36.0, 576.0, 756.0]),
        },
    );
    edited(
        cropped,
        Edit::RotatePages {
            pages: vec![0],
            degrees: 270,
        },
    )
}

/// A one-page form (US Letter, unturned) reading "Name:", "Agree:" and "Size:", with five fields on
/// page 0, their boxes in user space:
///
/// - `name`: a one-line text field, `[150 700 400 720]`;
/// - `agree`: a check box, `[150 660 170 680]`;
/// - `size`: a radio group of two buttons, exports `S` at `[150 630 170 650]` and `L` at
///   `[200 630 220 650]`;
/// - `color`: a combo box (not editable) offering `Red`, `Green` and `Blue`, `[150 600 300 620]`;
/// - `read_only_note`: a read-only text field, `[150 560 400 580]`.
///
/// Every field starts empty (unchecked, nothing chosen).
pub fn form_doc() -> Vec<u8> {
    let field = |rect: [f64; 4], kind: NewField, name: &str| Edit::AddField {
        page: 0,
        rect,
        kind,
        name: Some(name.to_owned()),
    };
    let radio = |rect: [f64; 4], export: &str| {
        field(
            rect,
            NewField::Radio {
                group: Some("size".to_owned()),
                export: export.to_owned(),
            },
            "size",
        )
    };
    edited_all(
        text_doc(&["Name:\n\nAgree:\n\nSize:"]),
        vec![
            field(
                [150.0, 700.0, 400.0, 720.0],
                NewField::Text { multiline: false },
                "name",
            ),
            field([150.0, 660.0, 170.0, 680.0], NewField::CheckBox, "agree"),
            radio([150.0, 630.0, 170.0, 650.0], "S"),
            radio([200.0, 630.0, 220.0, 650.0], "L"),
            field(
                [150.0, 600.0, 300.0, 620.0],
                NewField::Combo {
                    options: vec!["Red".to_owned(), "Green".to_owned(), "Blue".to_owned()],
                    editable: false,
                },
                "color",
            ),
            field(
                [150.0, 560.0, 400.0, 580.0],
                NewField::Text { multiline: false },
                "read_only_note",
            ),
            Edit::SetFieldProps {
                name: "read_only_note".to_owned(),
                props: Box::new(FieldProps {
                    read_only: Some(true),
                    ..FieldProps::default()
                }),
            },
        ],
    )
}

/// A one-page document (US Letter, unturned) reading "Marked page", with two comments: a highlight
/// over that line (user space `[72 706.8 136.2 717.8]`) and a sticky note whose icon's top-left
/// corner is at user `(72, 650)`, reading "Check this".
///
/// Unlike the other engine-made fixtures, its bytes differ from run to run: the engine mixes the
/// time of day into each comment's id (`/NM`), whatever the session's clock.
pub fn annotated_doc() -> Vec<u8> {
    let highlight = Shape::TextMarkup {
        kind: Markup::Highlight,
        quads: vec![[72.0, 717.8, 136.2, 717.8, 72.0, 706.8, 136.2, 706.8]],
    };
    let note = Shape::Note {
        at: [72.0, 650.0],
        icon: NoteIcon::default(),
    };
    let add = |shape: Shape, contents: &str| {
        Edit::AddAnnotation(NewAnnotation {
            page: 0,
            style: Style::default_for(&shape),
            shape,
            contents: contents.to_owned(),
            author: String::new(),
        })
    };
    edited_all(
        text_doc(&["Marked page"]),
        vec![add(highlight, ""), add(note, "Check this")],
    )
}

/// A one-page document containing only an image, so its page has no text layer. The 17x22 px grey
/// PNG is placed at 2 dpi, which makes the page US Letter (612 x 792 pt) like `text_doc`'s.
pub fn image_only_doc() -> Vec<u8> {
    let image = ("scan.png".to_owned(), GREY_PNG.to_vec());
    session()
        .create_from_images_with_resolution(&[image], ImageResolution::Dpi(2.0))
        .expect("the image page creates")
        .to_vec()
}

/// A one-page document whose page is a single line of text, `letters`, made of the letters "i", "j"
/// and "l" only: its text layer has one glyph for each, all on one line.
///
/// The engine's text importer wraps lines at the page width, so this is the one fixture written by
/// hand, as the page of a hostile or oddly made file would be: one string, drawn once. It is set in
/// a 1 pt font, which is what makes it fit. Each of those letters then advances 0.222 pt, so 60,000
/// of them are 13,320 pt long, within the widest page the PDF format allows (14,400 pt). A bigger
/// font does not fit the line on the page, and squeezing a bigger font loses glyphs: the engine
/// takes a glyph within a fifth of its height of another for a redraw of it, and drops it, and
/// 0.222 pt is just over a fifth of 1 pt.
pub fn one_line_doc(letters: &str) -> Vec<u8> {
    assert!(
        (1..=60_000).contains(&letters.len()),
        "the line has to fit the widest page"
    );
    assert!(
        letters.chars().all(|c| matches!(c, 'i' | 'j' | 'l')),
        "only letters that are 0.222 em wide fit"
    );
    let content = format!("BT /F1 1 Tf 1 0 0 1 10 400 Tm ({letters}) Tj ET");
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R >>".to_owned(),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_owned(),
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 14400 800] \
         /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>"
            .to_owned(),
        format!(
            "<< /Length {} >>\nstream\n{content}\nendstream",
            content.len()
        ),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".to_owned(),
    ];
    let pdf = write_pdf(&objects);
    // Pin the contract, as `text_doc` does: one page.
    let mut check = session();
    let id = check
        .open("fixture.pdf", None, Arc::new(pdf.clone()), None)
        .expect("the fixture opens");
    assert_eq!(
        check.get(id).expect("the fixture is open").info.pages.len(),
        1
    );
    pdf
}

/// A PDF written by hand from `objects`, the bodies of objects 1, 2, … in order, with object 1 its
/// catalog and a classic cross-reference table.
fn write_pdf(objects: &[String]) -> Vec<u8> {
    let mut pdf = b"%PDF-1.4\n".to_vec();
    let mut offsets = Vec::new();
    for (number, body) in objects.iter().enumerate() {
        offsets.push(pdf.len());
        pdf.extend(format!("{} 0 obj\n{body}\nendobj\n", number + 1).into_bytes());
    }
    // The cross-reference table: one 20-byte entry for the free object 0 and one for each object.
    let table = pdf.len();
    pdf.extend(format!("xref\n0 {}\n0000000000 65535 f \n", objects.len() + 1).into_bytes());
    for offset in offsets {
        pdf.extend(format!("{offset:010} 00000 n \n").into_bytes());
    }
    pdf.extend(
        format!(
            "trailer\n<< /Size {} /Root 1 0 R >>\nstartxref\n{table}\n%%EOF\n",
            objects.len() + 1
        )
        .into_bytes(),
    );
    pdf
}

/// A one-page form (US Letter) written by hand, whose fields are `fields`: the bodies of field
/// dictionaries that are also their widget (`/Subtype /Widget`, `/Rect`, `/P` are added), objects
/// 5, 6, … in order. Object 4 is an empty appearance stream, for fields' `/AP` to name as `4 0 R`.
pub fn hand_form_doc(fields: &[String]) -> Vec<u8> {
    let refs: Vec<String> = (0..fields.len())
        .map(|i| format!("{} 0 R", i + 5))
        .collect();
    let refs = refs.join(" ");
    let mut objects = vec![
        format!("<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [{refs}] >> >>"),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_owned(),
        format!("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [{refs}] >>"),
        "<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Length 0 >>\nstream\n\nendstream"
            .to_owned(),
    ];
    objects.extend(fields.iter().map(|body| {
        format!("<< /Type /Annot /Subtype /Widget /Rect [100 100 120 120] /P 3 0 R {body} >>")
    }));
    write_pdf(&objects)
}

/// A one-page document (US Letter, unturned) written by hand, whose page's `/Annots` lists `annots`
/// in order: the whole dictionaries of objects 4, 5, …, which may refer to one another by those
/// numbers. The catalog's form lists the objects `fields` names, so that a widget among them is a
/// field's; with none, the document has no form.
///
/// The engine always lists a comment's pop-up and replies after it; files made elsewhere need not, and
/// this is how the tests get those.
pub fn hand_annotated_doc(annots: &[&str], fields: &[u32]) -> Vec<u8> {
    let refs = |numbers: &mut dyn Iterator<Item = u32>| {
        numbers
            .map(|n| format!("{n} 0 R"))
            .collect::<Vec<_>>()
            .join(" ")
    };
    let listed = (4..).take(annots.len());
    let form = if fields.is_empty() {
        String::new()
    } else {
        format!(
            " /AcroForm << /Fields [{}] >>",
            refs(&mut fields.iter().copied())
        )
    };
    let mut objects = vec![
        format!("<< /Type /Catalog /Pages 2 0 R{form} >>"),
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>".to_owned(),
        format!(
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [{}] >>",
            refs(&mut listed.into_iter())
        ),
    ];
    objects.extend(annots.iter().map(|body| (*body).to_owned()));
    write_pdf(&objects)
}

/// A one-page document (US Letter, unturned) written by hand with two comments the file locks:
///
/// - a rectangle, user space `[100 600 200 700]`, whose flags are written as a real number
///   (`/F 128.0`): the comment list the engine reads when it opens a file takes it for unlocked, and
///   the engine's own changes for locked, so a change to it gets past the apps and the engine refuses
///   it;
/// - a text box reading "Locked", `[100 400 300 440]`, locked as usual (`/F 128`).
pub fn locked_markup_doc() -> Vec<u8> {
    hand_annotated_doc(
        &[
            "<< /Type /Annot /Subtype /Square /Rect [100 600 200 700] /C [1 0 0] /F 128.0 >>",
            "<< /Type /Annot /Subtype /FreeText /Rect [100 400 300 440] /Contents (Locked) \
             /DA (/Helv 12 Tf 0 0 0 rg) /F 128 >>",
        ],
        &[],
    )
}

/// `hand_form_doc` with `count` empty text fields, `f0`, `f1`, … all at the same place.
pub fn many_fields_doc(count: usize) -> Vec<u8> {
    let fields: Vec<String> = (0..count).map(|i| format!("/FT /Tx /T (f{i})")).collect();
    hand_form_doc(&fields)
}
