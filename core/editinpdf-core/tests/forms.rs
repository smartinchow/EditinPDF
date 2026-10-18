#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

mod fixtures;
mod support;

use editinpdf_core::{
    AnnotationKind, ChoiceOption, Edit, EditError, FieldValue, FormField, FormFieldKind,
    PdfDocument, Rect, SaveMode,
};
use support::{assert_rect_close, reopen};

fn field(doc: &PdfDocument, name: &str) -> FormField {
    doc.form_fields()
        .into_iter()
        .find(|f| f.name == name)
        .unwrap_or_else(|| panic!("no field {name}"))
}

fn text(text: &str) -> FieldValue {
    FieldValue::Text {
        text: text.to_owned(),
    }
}

#[test]
fn fields_are_listed_in_view_space() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    let fields = doc.form_fields();
    let name = fields.iter().find(|f| f.name == "name").unwrap();
    assert_eq!(name.kind, FormFieldKind::Text);
    let w = &name.widgets[0];
    assert_eq!(w.page, 0);
    // 792 - 720 = 72
    assert_rect_close(
        &w.rect,
        &Rect {
            x: 150.0,
            y: 72.0,
            width: 250.0,
            height: 20.0,
        },
        1.0,
    );
    assert_eq!(
        fields
            .iter()
            .find(|f| f.name == "size")
            .unwrap()
            .widgets
            .len(),
        2
    );
    assert!(
        fields
            .iter()
            .find(|f| f.name == "read_only_note")
            .unwrap()
            .read_only
    );
}

#[test]
fn every_field_reads_as_it_was_made() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    let names: Vec<String> = doc.form_fields().into_iter().map(|f| f.name).collect();
    assert_eq!(
        names,
        ["name", "agree", "size", "color", "read_only_note"],
        "in the document's order"
    );

    let name = field(&doc, "name");
    assert!(name.value.is_empty());
    assert!(!name.read_only && !name.multiline && !name.multi_select && !name.editable_choice);
    assert_eq!(name.max_len, None);
    assert!(name.options.is_empty());
    assert!(!name.widgets[0].is_on, "a text field has no on state");
    assert_eq!(name.widgets[0].on_state, None);

    let agree = field(&doc, "agree");
    assert_eq!(agree.kind, FormFieldKind::CheckBox);
    assert_eq!(agree.widgets.len(), 1);
    assert!(agree.widgets[0].on_state.is_some());
    assert!(!agree.widgets[0].is_on);

    let size = field(&doc, "size");
    assert_eq!(size.kind, FormFieldKind::Radio);
    let states: Vec<Option<&str>> = size.widgets.iter().map(|w| w.on_state.as_deref()).collect();
    assert_eq!(states, [Some("S"), Some("L")]);
    assert!(size.widgets.iter().all(|w| !w.is_on));
    assert_rect_close(
        &size.widgets[1].rect,
        &Rect {
            x: 200.0,
            y: 142.0,
            width: 20.0,
            height: 20.0,
        },
        1.0,
    );

    let color = field(&doc, "color");
    assert_eq!(color.kind, FormFieldKind::Combo);
    assert!(!color.editable_choice && !color.multi_select);
    let displays: Vec<&str> = color.options.iter().map(|o| o.display.as_str()).collect();
    assert_eq!(displays, ["Red", "Green", "Blue"]);
    assert_eq!(
        color.options[1],
        ChoiceOption {
            export: "Green".to_owned(),
            display: "Green".to_owned()
        }
    );
}

#[test]
fn a_document_without_a_form_has_no_fields() {
    let doc = PdfDocument::open(fixtures::text_doc(&["plain"]), None).unwrap();
    assert!(doc.form_fields().is_empty());
}

/// The view-space box of the `name` field (user `[150 700 400 720]` on a 612 x 792 page) on the
/// page turned by `/Rotate` 0, 90, 180 and 270.
#[test]
fn fields_are_in_view_space_at_every_rotation() {
    let expected = [
        (
            0,
            Rect {
                x: 150.0,
                y: 72.0,
                width: 250.0,
                height: 20.0,
            },
        ),
        // A quarter clockwise: the file's bottom-left corner is shown top-left, up is right.
        (
            90,
            Rect {
                x: 700.0,
                y: 150.0,
                width: 20.0,
                height: 250.0,
            },
        ),
        (
            180,
            Rect {
                x: 212.0,
                y: 700.0,
                width: 250.0,
                height: 20.0,
            },
        ),
        (
            270,
            Rect {
                x: 72.0,
                y: 212.0,
                width: 20.0,
                height: 250.0,
            },
        ),
    ];
    for (degrees, rect) in expected {
        let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
        if degrees != 0 {
            doc.apply(
                Edit::RotatePages {
                    pages: vec![0],
                    degrees,
                },
                0,
            )
            .unwrap();
        }
        assert_eq!(
            doc.page_info(0).unwrap().rotation_degrees,
            degrees.unsigned_abs()
        );
        let w = &field(&doc, "name").widgets[0];
        assert_rect_close(&w.rect, &rect, 1.0);
        // Read again after saving, the box is the same.
        let back = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
        assert_rect_close(&field(&back, "name").widgets[0].rect, &rect, 1.0);
    }
}

#[test]
fn values_persist_after_save() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    let edits = [
        ("name", text("Ada")),
        ("agree", FieldValue::Checked { on: true }),
        (
            "size",
            FieldValue::Radio {
                state: Some("L".into()),
            },
        ),
        (
            "color",
            FieldValue::Choice {
                values: vec!["Green".into()],
            },
        ),
    ];
    for (i, (n, v)) in edits.into_iter().enumerate() {
        doc.apply(
            Edit::SetFieldValue {
                name: n.into(),
                value: v,
            },
            i as u64,
        )
        .unwrap();
    }
    let back = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
    let f = |n: &str| field(&back, n);
    assert_eq!(f("name").value, vec!["Ada"]);
    assert!(f("agree").widgets[0].is_on);
    assert!(
        f("size")
            .widgets
            .iter()
            .any(|w| w.is_on && w.on_state.as_deref() == Some("L"))
    );
    assert!(
        f("size")
            .widgets
            .iter()
            .any(|w| !w.is_on && w.on_state.as_deref() == Some("S")),
        "only one button of a group is on"
    );
    assert_eq!(f("color").value, vec!["Green"]);
    let out = doc.undo().unwrap();
    assert_eq!(out.revision, 5);
    assert!(field(&doc, "color").value.is_empty());
    // Unchecking turns the box off again.
    doc.apply(
        Edit::SetFieldValue {
            name: "agree".into(),
            value: FieldValue::Checked { on: false },
        },
        5,
    )
    .unwrap();
    assert!(!field(&doc, "agree").widgets[0].is_on);
}

#[test]
fn a_field_edit_is_labelled_for_the_edit_menu() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    let out = doc
        .apply(
            Edit::SetFieldValue {
                name: "name".into(),
                value: text("Ada"),
            },
            0,
        )
        .unwrap();
    assert_eq!(out.revision, 1);
    assert!(out.label.contains("name"), "{}", out.label);
}

#[test]
fn unknown_field_is_invalid() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    assert!(matches!(
        doc.apply(
            Edit::SetFieldValue {
                name: "nope".into(),
                value: text("x")
            },
            0
        ),
        Err(EditError::Invalid { .. })
    ));
    // The bridge refuses it itself, before the engine sees it (the engine's refusal reads
    // "there is no field named ...").
    assert_eq!(
        doc.apply(
            Edit::SetFieldValue {
                name: "nope".into(),
                value: text("x")
            },
            0
        ),
        Err(EditError::Invalid {
            message: "there is no form field named \"nope\"".to_owned()
        })
    );
    // A name is matched exactly.
    assert!(matches!(
        doc.apply(
            Edit::SetFieldValue {
                name: "Name".into(),
                value: text("x")
            },
            0
        ),
        Err(EditError::Invalid { .. })
    ));
    // Within a step too, and then nothing of the step is made.
    let step = doc.apply_all(
        "Fill".into(),
        vec![
            Edit::SetFieldValue {
                name: "name".into(),
                value: text("Ada"),
            },
            Edit::SetFieldValue {
                name: "nope".into(),
                value: text("x"),
            },
        ],
        0,
    );
    assert!(matches!(step, Err(EditError::Invalid { .. })), "{step:?}");
    assert_eq!(doc.revision(), 0, "nothing changed");
    assert!(field(&doc, "name").value.is_empty());
    assert!(!doc.can_undo());
}

#[test]
fn a_document_without_a_form_refuses_a_field_value() {
    let doc = PdfDocument::open(fixtures::text_doc(&["plain"]), None).unwrap();
    let result = doc.apply(
        Edit::SetFieldValue {
            name: "name".into(),
            value: text("x"),
        },
        0,
    );
    assert_eq!(
        result,
        Err(EditError::Invalid {
            message: "there is no form field named \"name\"".to_owned()
        })
    );
    assert_eq!(doc.revision(), 0);
}

#[test]
fn values_that_do_not_fit_the_field_are_invalid() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    let refused = [
        ("read_only_note", text("x")),
        (
            "size",
            FieldValue::Radio {
                state: Some("XL".into()),
            },
        ),
        (
            "agree",
            FieldValue::Choice {
                values: vec!["Green".into()],
            },
        ),
    ];
    for (name, value) in refused {
        let result = doc.apply(
            Edit::SetFieldValue {
                name: name.into(),
                value: value.clone(),
            },
            0,
        );
        assert!(
            matches!(result, Err(EditError::Invalid { .. })),
            "{name} = {value:?}: {result:?}"
        );
    }
    assert_eq!(doc.revision(), 0, "nothing changed");
    assert!(field(&doc, "read_only_note").value.is_empty());
}

#[test]
fn a_document_that_forbids_changes_refuses_for_its_own_reason_first() {
    // Its security settings forbid any change, form filling included: that is the refusal, whether
    // or not the field exists.
    let doc = PdfDocument::open(fixtures::restricted_doc(&["x"], "owner"), None).unwrap();
    assert!(!doc.capabilities().can_fill_forms);
    let result = doc.apply(
        Edit::SetFieldValue {
            name: "nope".into(),
            value: text("x"),
        },
        0,
    );
    assert!(
        matches!(result, Err(EditError::NotPermitted { .. })),
        "{result:?}"
    );
}

/// A field is addressed by its name, which no page change alters: a step may fill fields and
/// insert, delete, move or turn pages together.
#[test]
fn a_step_may_fill_fields_and_change_pages() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    let fill = |value: &str| Edit::SetFieldValue {
        name: "name".into(),
        value: text(value),
    };
    doc.apply_all(
        "x".into(),
        vec![
            Edit::InsertBlankPage {
                at: 0,
                width_pt: 100.0,
                height_pt: 100.0,
            },
            fill("one"),
        ],
        0,
    )
    .unwrap();
    assert_eq!(doc.page_count(), 2);
    let name = field(&doc, "name");
    assert_eq!(name.value, vec!["one"]);
    assert_eq!(name.widgets[0].page, 1, "the field's page moved down");
    doc.apply_all(
        "x".into(),
        vec![
            Edit::MovePages {
                pages: vec![1],
                to: 0,
            },
            Edit::RotatePages {
                pages: vec![0],
                degrees: 90,
            },
            fill("two"),
        ],
        1,
    )
    .unwrap();
    let name = field(&doc, "name");
    assert_eq!((name.value[0].as_str(), name.widgets[0].page), ("two", 0));
    doc.apply_all(
        "x".into(),
        vec![Edit::DeletePages { pages: vec![1] }, fill("three")],
        2,
    )
    .unwrap();
    assert_eq!(doc.page_count(), 1);
    assert_eq!(field(&doc, "name").value, vec!["three"]);
}

#[test]
fn the_annotated_fixture_has_a_highlight_and_a_note() {
    let doc = PdfDocument::open(fixtures::annotated_doc(), None).unwrap();
    let list = doc.annotations();
    let kinds: Vec<&AnnotationKind> = list.iter().map(|a| &a.kind).collect();
    assert_eq!(kinds, [&AnnotationKind::Highlight, &AnnotationKind::Note]);
    // The highlight covers the line of text.
    let line = doc.select_range(0, 0, 11).unwrap();
    assert_rect_close(&list[0].rect, &line.rects[0], 2.0);
    assert_eq!(list[1].contents.as_deref(), Some("Check this"));
    assert!(doc.form_fields().is_empty());
}
