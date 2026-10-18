//! The document's form fields, as the apps list and fill them.

use pdfcraft_engine::{FormFieldKind as EngineKind, field_flags};

use crate::geometry;
use crate::{EditError, FieldValue, Rect};

/// What kind of form field a field is.
#[derive(uniffi::Enum, Clone, Copy, Debug, PartialEq)]
pub enum FormFieldKind {
    Text,
    CheckBox,
    /// A group of radio buttons, one widget each, of which at most one is on.
    Radio,
    /// A drop-down list, which may also take typed text (`FormField.editable_choice`).
    Combo,
    /// A list box, which may allow several choices (`FormField.multi_select`).
    List,
    PushButton,
    /// A signature field.
    Signature,
}

impl FormFieldKind {
    fn from_engine(kind: EngineKind) -> Self {
        // Every engine variant is named so that one added upstream stops the build here.
        match kind {
            EngineKind::Text => Self::Text,
            EngineKind::CheckBox => Self::CheckBox,
            EngineKind::Radio => Self::Radio,
            EngineKind::Combo => Self::Combo,
            EngineKind::List => Self::List,
            EngineKind::PushButton => Self::PushButton,
            EngineKind::Signature => Self::Signature,
        }
    }
}

/// One of the choices a combo box or list box offers.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct ChoiceOption {
    /// What choosing it sets the field's value to (`FieldValue::Choice`).
    pub export: String,
    /// What it shows.
    pub display: String,
}

/// One place on a page where a field is shown and filled in.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct FormWidget {
    /// The 0-based page it is on.
    pub page: u32,
    /// Where it is, in view space.
    pub rect: Rect,
    /// Check boxes and radio buttons: the state this widget turns on (for a radio button, what
    /// `FieldValue::Radio` selects it by). Nothing for other fields.
    pub on_state: Option<String>,
    /// Check boxes and radio buttons: whether it is on now. Always off for other fields.
    pub is_on: bool,
}

/// A form field: one value, shown in one or more widgets.
#[derive(uniffi::Record, Clone, Debug, PartialEq)]
pub struct FormField {
    /// The field's full name (`parent.child`), which `Edit::SetFieldValue` addresses it by.
    pub name: String,
    pub kind: FormFieldKind,
    /// Text field: its text. Check box or radio group: the state that is on (empty when off).
    /// Combo or list box: the export values chosen.
    pub value: Vec<String>,
    /// Combo and list boxes: what they offer, in order. Empty for other fields.
    pub options: Vec<ChoiceOption>,
    /// The file forbids filling it in.
    pub read_only: bool,
    /// Text field: it takes several lines.
    pub multiline: bool,
    /// List box: several choices may be made.
    pub multi_select: bool,
    /// Combo box: text may be typed as well as chosen.
    pub editable_choice: bool,
    /// Text field: the most characters it takes, when it has a limit.
    pub max_len: Option<u32>,
    /// Where it is shown, in the document's order. Hidden widgets, and widgets on no page of the
    /// document, are left out; a field none of whose widgets is shown is not listed at all.
    pub widgets: Vec<FormWidget>,
}

/// The most fields `PdfDocument::form_fields` lists: the first ones, in the document's order.
pub(crate) const MAX_LISTED_FIELDS: usize = 5_000;
/// The most options, and the most chosen values, a listed field carries: the first ones.
pub(crate) const MAX_LISTED_OPTIONS: usize = 1_000;
/// The most widgets a listed field carries: the first ones shown.
pub(crate) const MAX_LISTED_WIDGETS: usize = 100;

/// The most characters a text field's value may have.
const MAX_TEXT_CHARS: usize = 10_000;
/// The most values one choice may make.
const MAX_CHOICE_VALUES: usize = 1_000;
/// The most characters one chosen value, or a radio button's state, may have.
const MAX_CHOICE_CHARS: usize = 1_000;

/// What `list` found: the fields as the apps see them, and whether any was left out or listed
/// short for the caps above.
pub(crate) struct Listing {
    pub(crate) fields: Vec<FormField>,
    pub(crate) truncated: bool,
}

/// The fields of the document the engine read, in the document's order, with their widgets in
/// view space, within the caps above: at most `MAX_LISTED_FIELDS` fields, each with at most
/// `MAX_LISTED_OPTIONS` options and values and `MAX_LISTED_WIDGETS` widgets. A hostile file can
/// have far more, and the list crosses the FFI boundary in one piece, under the state lock; the
/// walk stops once the caps are reached. Only reads what the engine read and turns boxes with the
/// page's plain arithmetic: nothing here can panic.
pub(crate) fn list(
    pages: &[pdfcraft_render::PageInfo],
    fields: &[pdfcraft_engine::FormField],
) -> Listing {
    let mut listed = Vec::new();
    let mut truncated = false;
    for field in fields {
        let mut shown = field
            .widgets
            .iter()
            .filter(|w| !w.hidden)
            .filter_map(|w| widget(pages, w));
        let widgets: Vec<FormWidget> = shown.by_ref().take(MAX_LISTED_WIDGETS).collect();
        if widgets.is_empty() {
            continue;
        }
        if listed.len() == MAX_LISTED_FIELDS {
            // One more field would be listed: the list is short of the document's.
            truncated = true;
            break;
        }
        truncated |= shown.next().is_some()
            || field.options.len() > MAX_LISTED_OPTIONS
            || field.value.len() > MAX_LISTED_OPTIONS;
        listed.push(FormField {
            name: field.name.clone(),
            kind: FormFieldKind::from_engine(field.kind),
            value: field
                .value
                .iter()
                .take(MAX_LISTED_OPTIONS)
                .cloned()
                .collect(),
            options: field
                .options
                .iter()
                .take(MAX_LISTED_OPTIONS)
                .map(|(export, display)| ChoiceOption {
                    export: export.clone(),
                    display: display.clone(),
                })
                .collect(),
            read_only: field.read_only(),
            multiline: field.has(field_flags::MULTILINE),
            multi_select: field.has(field_flags::MULTI_SELECT),
            editable_choice: field.has(field_flags::EDIT),
            max_len: field
                .max_len
                .map(|len| u32::try_from(len).unwrap_or(u32::MAX)),
            widgets,
        });
    }
    Listing {
        fields: listed,
        truncated,
    }
}

/// The widget `w` as the apps see it; nothing when it is on no page the document has.
fn widget(
    pages: &[pdfcraft_render::PageInfo],
    w: &pdfcraft_engine::FormWidget,
) -> Option<FormWidget> {
    let index = w.page?;
    let page = pages.get(index)?;
    Some(FormWidget {
        page: u32::try_from(index).ok()?,
        rect: geometry::user_rect_to_view(page, w.rect),
        on_state: w.on_state.clone(),
        is_on: is_on(w.on_state.as_deref(), w.state.as_deref()),
    })
}

/// Whether a widget whose on state is `on_state` shows as on in the appearance state `state`. A
/// widget without an on state (a text field's, say) is never on, and neither is one whose state is
/// `Off`.
fn is_on(on_state: Option<&str>, state: Option<&str>) -> bool {
    on_state.is_some() && state == on_state && state != Some("Off")
}

/// The engine's value for `value`, once it is known to be within the caps above: a text of at
/// most `MAX_TEXT_CHARS` characters, at most `MAX_CHOICE_VALUES` chosen values of at most
/// `MAX_CHOICE_CHARS` characters each, a radio state of at most `MAX_CHOICE_CHARS` characters.
/// A field's own limit (`FormField.max_len`) is the engine's to apply.
pub(crate) fn value_to_engine(
    value: &FieldValue,
) -> Result<pdfcraft_engine::FieldValue, EditError> {
    let long = |text: &str, most: usize| text.chars().nth(most).is_some();
    let refused = match value {
        FieldValue::Text { text } => long(text, MAX_TEXT_CHARS)
            .then(|| format!("a field's text has at most {MAX_TEXT_CHARS} characters")),
        FieldValue::Checked { .. } => None,
        FieldValue::Radio { state } => state
            .as_deref()
            .is_some_and(|state| long(state, MAX_CHOICE_CHARS))
            .then(|| format!("a radio button's state has at most {MAX_CHOICE_CHARS} characters")),
        FieldValue::Choice { values } => {
            if values.len() > MAX_CHOICE_VALUES {
                Some(format!(
                    "a choice has at most {MAX_CHOICE_VALUES} values, not {}",
                    values.len()
                ))
            } else {
                values
                    .iter()
                    .any(|v| long(v, MAX_CHOICE_CHARS))
                    .then(|| format!("a chosen value has at most {MAX_CHOICE_CHARS} characters"))
            }
        }
    };
    if let Some(message) = refused {
        return Err(EditError::Invalid { message });
    }
    Ok(engine_value(value))
}

/// The engine's value for `value`, as it is.
fn engine_value(value: &FieldValue) -> pdfcraft_engine::FieldValue {
    use pdfcraft_engine::FieldValue as Engine;
    match value {
        FieldValue::Text { text } => Engine::Text(text.clone()),
        FieldValue::Checked { on } => Engine::Check(*on),
        FieldValue::Radio { state } => Engine::Radio(state.clone()),
        FieldValue::Choice { values } => Engine::Choice(values.clone()),
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use std::sync::Arc;

    use pdfcraft_engine::{Edit, NewField, Session};

    use super::*;

    /// The fields of a one-page document with a text field `t` and a check box `c`, as the engine
    /// reads them, and its pages.
    fn engine_fields() -> (
        Vec<pdfcraft_render::PageInfo>,
        Vec<pdfcraft_engine::FormField>,
    ) {
        let mut session = Session::new();
        let bytes = session.create_from_text("form", "x").unwrap();
        let id = session.open("form.pdf", None, bytes, None).unwrap();
        for (kind, name, rect) in [
            (
                NewField::Text { multiline: true },
                "t",
                [100.0, 700.0, 200.0, 720.0],
            ),
            (NewField::CheckBox, "c", [100.0, 600.0, 120.0, 620.0]),
        ] {
            session
                .apply(
                    id,
                    Edit::AddField {
                        page: 0,
                        rect,
                        kind,
                        name: Some(name.to_owned()),
                    },
                )
                .unwrap();
        }
        let doc = session.get(id).unwrap();
        (
            doc.info.pages.clone(),
            Arc::unwrap_or_clone(doc.form.clone()),
        )
    }

    #[test]
    fn on_means_the_widgets_own_state_and_not_off() {
        assert!(is_on(Some("Yes"), Some("Yes")));
        assert!(!is_on(Some("Yes"), Some("Off")));
        assert!(!is_on(Some("Yes"), None));
        assert!(!is_on(Some("Off"), Some("Off")));
        assert!(!is_on(None, None), "a text field's widget is never on");
        assert!(!is_on(None, Some("Yes")));
    }

    #[test]
    fn hidden_widgets_and_widgets_on_no_page_are_left_out() {
        let (pages, fields) = engine_fields();
        let listed = list(&pages, &fields).fields;
        assert_eq!(listed.len(), 2);
        assert!(listed[0].multiline);
        assert_eq!(listed[1].kind, FormFieldKind::CheckBox);

        let mut hidden = fields.clone();
        hidden[0].widgets[0].hidden = true;
        let names: Vec<String> = list(&pages, &hidden)
            .fields
            .into_iter()
            .map(|f| f.name)
            .collect();
        assert_eq!(names, ["c"], "a field with no shown widget is not listed");

        let mut off_page = fields.clone();
        off_page[1].widgets[0].page = None;
        off_page[0].widgets[0].page = Some(1);
        assert!(list(&pages, &off_page).fields.is_empty());

        // A field with one widget shown and one not keeps the shown one.
        let mut mixed = fields;
        let mut extra = mixed[1].widgets[0].clone();
        extra.hidden = true;
        mixed[1].widgets.push(extra);
        let listing = list(&pages, &mixed);
        assert_eq!(listing.fields[1].widgets.len(), 1);
        assert!(!listing.truncated, "a hidden widget is not a cap");
    }

    #[test]
    fn a_huge_limit_is_held_at_the_largest_the_apps_can_read() {
        let (pages, mut fields) = engine_fields();
        fields[0].max_len = Some(usize::MAX);
        assert_eq!(list(&pages, &fields).fields[0].max_len, Some(u32::MAX));
    }

    #[test]
    fn every_value_becomes_the_engines() {
        use pdfcraft_engine::FieldValue as Engine;
        let cases = [
            (
                FieldValue::Text {
                    text: "a".to_owned(),
                },
                Engine::Text("a".to_owned()),
            ),
            (FieldValue::Checked { on: true }, Engine::Check(true)),
            (FieldValue::Radio { state: None }, Engine::Radio(None)),
            (
                FieldValue::Choice {
                    values: vec!["x".to_owned()],
                },
                Engine::Choice(vec!["x".to_owned()]),
            ),
        ];
        for (value, engine) in cases {
            assert_eq!(value_to_engine(&value), Ok(engine));
        }
    }

    #[test]
    fn the_list_stops_at_its_caps_and_says_so() {
        let (pages, fields) = engine_fields();
        assert!(!list(&pages, &fields).truncated);

        // More fields than the cap: the first ones, and the list says it is short.
        let many: Vec<_> = fields
            .iter()
            .cycle()
            .take(MAX_LISTED_FIELDS + 1)
            .cloned()
            .collect();
        let listing = list(&pages, &many);
        assert_eq!(listing.fields.len(), MAX_LISTED_FIELDS);
        assert!(listing.truncated);
        // Exactly the cap is the whole list.
        let listing = list(&pages, &many[..MAX_LISTED_FIELDS]);
        assert_eq!(listing.fields.len(), MAX_LISTED_FIELDS);
        assert!(!listing.truncated);
        // A field no widget of which is shown past the cap does not count as one left out.
        let mut hidden_last = many.clone();
        hidden_last[MAX_LISTED_FIELDS].widgets.clear();
        assert!(!list(&pages, &hidden_last).truncated);

        // Too many widgets, options or chosen values in one field.
        let mut widgets = fields.clone();
        let w = widgets[1].widgets[0].clone();
        widgets[1].widgets = vec![w; MAX_LISTED_WIDGETS + 1];
        let listing = list(&pages, &widgets);
        assert_eq!(listing.fields[1].widgets.len(), MAX_LISTED_WIDGETS);
        assert!(listing.truncated);

        let mut options = fields.clone();
        options[0].options = vec![("a".to_owned(), "A".to_owned()); MAX_LISTED_OPTIONS + 1];
        options[0].value = vec!["a".to_owned(); MAX_LISTED_OPTIONS + 1];
        let listing = list(&pages, &options);
        assert_eq!(listing.fields[0].options.len(), MAX_LISTED_OPTIONS);
        assert_eq!(listing.fields[0].value.len(), MAX_LISTED_OPTIONS);
        assert!(listing.truncated);

        let mut values = fields;
        values[0].value = vec!["a".to_owned(); MAX_LISTED_OPTIONS + 1];
        assert!(list(&pages, &values).truncated, "values alone");
    }

    #[test]
    fn values_beyond_the_caps_are_invalid() {
        let invalid = |value: FieldValue| {
            assert!(
                matches!(value_to_engine(&value), Err(EditError::Invalid { .. })),
                "{value:?}"
            );
        };
        let ok = |value: FieldValue| assert!(value_to_engine(&value).is_ok(), "{value:?}");
        // Characters, not bytes: 10,000 two-byte letters are within the cap.
        ok(FieldValue::Text {
            text: "é".repeat(MAX_TEXT_CHARS),
        });
        invalid(FieldValue::Text {
            text: "a".repeat(MAX_TEXT_CHARS + 1),
        });
        ok(FieldValue::Choice {
            values: vec!["a".repeat(MAX_CHOICE_CHARS); MAX_CHOICE_VALUES],
        });
        invalid(FieldValue::Choice {
            values: vec!["a".to_owned(); MAX_CHOICE_VALUES + 1],
        });
        invalid(FieldValue::Choice {
            values: vec!["a".repeat(MAX_CHOICE_CHARS + 1)],
        });
        ok(FieldValue::Radio {
            state: Some("a".repeat(MAX_CHOICE_CHARS)),
        });
        invalid(FieldValue::Radio {
            state: Some("a".repeat(MAX_CHOICE_CHARS + 1)),
        });
    }
}
