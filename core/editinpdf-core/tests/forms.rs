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

#[test]
fn a_huge_form_is_listed_up_to_the_cap_and_says_so() {
    let doc = PdfDocument::open(fixtures::many_fields_doc(5_001), None).unwrap();
    let fields = doc.form_fields();
    assert_eq!(fields.len(), 5_000);
    assert_eq!(fields[4_999].name, "f4999", "the first ones");
    assert!(doc.form_fields_truncated());
    // Exactly the cap is the whole form.
    let doc = PdfDocument::open(fixtures::many_fields_doc(5_000), None).unwrap();
    assert_eq!(doc.form_fields().len(), 5_000);
    assert!(!doc.form_fields_truncated());
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    assert!(!doc.form_fields_truncated());
}

#[test]
fn over_long_values_are_invalid() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    let refused = [
        ("name", text(&"a".repeat(10_001))),
        (
            "color",
            FieldValue::Choice {
                values: vec!["Green".into(); 1_001],
            },
        ),
        (
            "color",
            FieldValue::Choice {
                values: vec!["G".repeat(1_001)],
            },
        ),
    ];
    for (name, value) in refused {
        let result = doc.apply(
            Edit::SetFieldValue {
                name: name.into(),
                value,
            },
            0,
        );
        assert!(
            matches!(result, Err(EditError::Invalid { .. })),
            "{result:?}"
        );
    }
    assert_eq!(doc.revision(), 0, "nothing changed");
    // 10,000 characters is a text the field takes.
    doc.apply(
        Edit::SetFieldValue {
            name: "name".into(),
            value: text(&"a".repeat(10_000)),
        },
        0,
    )
    .unwrap();
    assert_eq!(field(&doc, "name").value[0].chars().count(), 10_000);
}

#[test]
fn a_step_of_more_than_10_000_edits_is_invalid() {
    let doc = PdfDocument::open(fixtures::form_doc(), None).unwrap();
    let fill = Edit::SetFieldValue {
        name: "name".into(),
        value: text("x"),
    };
    let result = doc.apply_all("x".into(), vec![fill.clone(); 10_001], 0);
    assert!(
        matches!(result, Err(EditError::Invalid { .. })),
        "{result:?}"
    );
    assert_eq!(doc.revision(), 0, "nothing changed");
    doc.apply_all("x".into(), vec![fill; 10_000], 0).unwrap();
    assert_eq!(field(&doc, "name").value, vec!["x"]);
}

/// What a check box written by another program reads as today: its widget's on state is the
/// first of its appearance states that is not `Off`, and it is on only when its appearance state
/// (`/AS`) is that one. `value` is the field's own value (`/V`) either way.
#[test]
fn check_boxes_with_odd_appearances_read_as_they_are_shown() {
    let doc = PdfDocument::open(
        fixtures::hand_form_doc(&[
            // Two "on" looks, showing the second.
            "/FT /Btn /T (multi) /AP << /N << /A 4 0 R /B 4 0 R /Off 4 0 R >> >> /AS /B /V /B"
                .to_owned(),
            // On by its value, but with no appearance state, so it shows off.
            "/FT /Btn /T (no_as) /AP << /N << /Yes 4 0 R /Off 4 0 R >> >> /V /Yes".to_owned(),
        ]),
        None,
    )
    .unwrap();
    let multi = field(&doc, "multi");
    assert_eq!(multi.kind, FormFieldKind::CheckBox);
    assert_eq!(multi.value, vec!["B"]);
    assert_eq!(multi.widgets[0].on_state.as_deref(), Some("A"));
    assert!(!multi.widgets[0].is_on);
    let no_as = field(&doc, "no_as");
    assert_eq!(no_as.value, vec!["Yes"]);
    assert_eq!(no_as.widgets[0].on_state.as_deref(), Some("Yes"));
    assert!(!no_as.widgets[0].is_on);
}

/// The premise of the app's tests that open `form-kinds.pdf`: which fields it has, where, and of
/// what kind.
#[test]
fn the_form_kinds_fixture_reads_as_the_app_tests_expect() {
    let doc = PdfDocument::open(fixtures::form_kinds_doc(), None).unwrap();
    assert_eq!(doc.page_count(), 2);
    let names: Vec<String> = doc.form_fields().into_iter().map(|f| f.name).collect();
    assert_eq!(
        names,
        [
            "zip", "city", "toppings", "submit", "sign", "notes", "second"
        ]
    );
    let zip = field(&doc, "zip");
    assert_eq!(
        (zip.kind, zip.max_len, zip.multiline),
        (FormFieldKind::Text, Some(5), false)
    );
    let city = field(&doc, "city");
    assert_eq!(city.kind, FormFieldKind::Combo);
    assert!(city.editable_choice && !city.multi_select);
    assert_eq!(
        city.options
            .iter()
            .map(|o| o.display.as_str())
            .collect::<Vec<_>>(),
        ["Paris", "Rome"]
    );
    let toppings = field(&doc, "toppings");
    assert_eq!(toppings.kind, FormFieldKind::List);
    assert!(toppings.multi_select && !toppings.editable_choice);
    assert_eq!(toppings.options.len(), 3);
    assert_eq!(field(&doc, "submit").kind, FormFieldKind::PushButton);
    assert_eq!(field(&doc, "sign").kind, FormFieldKind::Signature);
    let notes = field(&doc, "notes");
    assert!(notes.multiline);
    // 792 - 160 = 632: near the bottom of the page.
    assert_rect_close(
        &notes.widgets[0].rect,
        &Rect {
            x: 72.0,
            y: 632.0,
            width: 468.0,
            height: 80.0,
        },
        1.0,
    );
    assert_eq!(field(&doc, "second").widgets[0].page, 1);
    assert!(doc.capabilities().can_fill_forms);

    // Several choices of a list box, and a typed one of a combo box, are taken and kept.
    doc.apply(
        Edit::SetFieldValue {
            name: "toppings".into(),
            value: FieldValue::Choice {
                values: vec!["Cheese".into(), "Peppers".into()],
            },
        },
        0,
    )
    .unwrap();
    doc.apply(
        Edit::SetFieldValue {
            name: "city".into(),
            value: FieldValue::Choice {
                values: vec!["Oslo".into()],
            },
        },
        1,
    )
    .unwrap();
    let back = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
    assert_eq!(field(&back, "toppings").value, vec!["Cheese", "Peppers"]);
    assert_eq!(field(&back, "city").value, vec!["Oslo"]);
}

/// The premise of the app's tests that open `restricted-form.pdf`: it lists the form's fields and
/// refuses to fill them in, for its own reason.
#[test]
fn the_restricted_form_fixture_lists_its_fields_and_forbids_filling() {
    let doc = PdfDocument::open(fixtures::restricted_form_doc(), None).unwrap();
    let caps = doc.capabilities();
    assert!(!caps.can_fill_forms && caps.is_encrypted);
    assert_eq!(doc.form_fields().len(), 5);
    let result = doc.apply(
        Edit::SetFieldValue {
            name: "name".into(),
            value: text("x"),
        },
        0,
    );
    assert!(
        matches!(result, Err(EditError::NotPermitted { .. })),
        "{result:?}"
    );
}

/// The premise of the app's tests that open `truncated-form.pdf`: its one field is listed with the
/// first 1,000 of its options, and the listing says it left some out.
#[test]
fn the_truncated_form_fixture_is_listed_short_and_says_so() {
    let doc = PdfDocument::open(fixtures::truncated_form_doc(), None).unwrap();
    let fields = doc.form_fields();
    assert_eq!(fields.len(), 1);
    assert_eq!(fields[0].kind, FormFieldKind::Combo);
    assert_eq!(fields[0].options.len(), 1_000);
    assert!(doc.form_fields_truncated());
    assert!(
        !PdfDocument::open(fixtures::form_doc(), None)
            .unwrap()
            .form_fields_truncated()
    );
}

/// The bridge runs no script a document carries: a field's keystroke, validate, calculate and
/// format scripts have no time or memory limit in the engine. The built-in calculations the engine
/// works out natively (a sum, here) still happen.
#[test]
fn filling_a_field_runs_none_of_the_forms_scripts() {
    let doc = PdfDocument::open(fixtures::scripted_form_doc(), None).unwrap();
    doc.apply(
        Edit::SetFieldValue {
            name: "typed".into(),
            value: text("hello"),
        },
        0,
    )
    .unwrap();
    assert_eq!(field(&doc, "typed").value, ["hello"]);
    assert!(
        field(&doc, "echo").value.is_empty(),
        "the keystroke script did not run"
    );
    assert!(
        field(&doc, "computed").value.is_empty(),
        "nor the calculate script"
    );
    doc.apply(
        Edit::SetFieldValue {
            name: "amount".into(),
            value: text("2"),
        },
        1,
    )
    .unwrap();
    assert_eq!(field(&doc, "total").value, ["2"], "a built-in sum is made");
    assert!(field(&doc, "computed").value.is_empty());
    // Opened again from what was saved, nothing has run either.
    let back = reopen(doc.save(SaveMode::Incremental).unwrap(), None);
    assert!(field(&back, "echo").value.is_empty() && field(&back, "computed").value.is_empty());
}
