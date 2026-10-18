//! The document's form fields, as the apps list and fill them.

use pdfcraft_engine::{FormFieldKind as EngineKind, field_flags};

use crate::geometry;
use crate::{FieldValue, Rect};

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

/// The fields of the document the engine read, in the document's order, with their widgets in
/// view space. Only reads what the engine read and turns boxes with the page's plain arithmetic:
/// nothing here can panic.
pub(crate) fn list(
    pages: &[pdfcraft_render::PageInfo],
    fields: &[pdfcraft_engine::FormField],
) -> Vec<FormField> {
    fields
        .iter()
        .filter_map(|field| {
            let widgets: Vec<FormWidget> = field
                .widgets
                .iter()
                .filter(|w| !w.hidden)
                .filter_map(|w| widget(pages, w))
                .collect();
            if widgets.is_empty() {
                return None;
            }
            Some(FormField {
                name: field.name.clone(),
                kind: FormFieldKind::from_engine(field.kind),
                value: field.value.clone(),
                options: field
                    .options
                    .iter()
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
            })
        })
        .collect()
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

/// The engine's value for `value`.
pub(crate) fn value_to_engine(value: &FieldValue) -> pdfcraft_engine::FieldValue {
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
        let listed = list(&pages, &fields);
        assert_eq!(listed.len(), 2);
        assert!(listed[0].multiline);
        assert_eq!(listed[1].kind, FormFieldKind::CheckBox);

        let mut hidden = fields.clone();
        hidden[0].widgets[0].hidden = true;
        let names: Vec<String> = list(&pages, &hidden).into_iter().map(|f| f.name).collect();
        assert_eq!(names, ["c"], "a field with no shown widget is not listed");

        let mut off_page = fields.clone();
        off_page[1].widgets[0].page = None;
        off_page[0].widgets[0].page = Some(1);
        assert!(list(&pages, &off_page).is_empty());

        // A field with one widget shown and one not keeps the shown one.
        let mut mixed = fields;
        let mut extra = mixed[1].widgets[0].clone();
        extra.hidden = true;
        mixed[1].widgets.push(extra);
        assert_eq!(list(&pages, &mixed)[1].widgets.len(), 1);
    }

    #[test]
    fn a_huge_limit_is_held_at_the_largest_the_apps_can_read() {
        let (pages, mut fields) = engine_fields();
        fields[0].max_len = Some(usize::MAX);
        assert_eq!(list(&pages, &fields)[0].max_len, Some(u32::MAX));
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
            assert_eq!(value_to_engine(&value), engine);
        }
    }
}
