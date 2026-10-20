import SwiftUI

/// The sheet a note is written and read in (`DocumentModel.noteDraft`): its text, Save and Cancel.
/// For a new note, Save is there once something other than spaces is written; for a note on the page,
/// once its text is changed. While the text differs from what the sheet opened with, a swipe does not
/// put the sheet away (and what was written with it): Cancel does, on purpose.
///
/// The text is the reader's, and is never logged.
struct NoteEditorSheet: View {
    let draft: NoteDraft
    /// Saves the text written: the screen closes the sheet and has the model add or change the note.
    let save: (String) -> Void
    /// Closes the sheet; nothing changes.
    let cancel: () -> Void

    @State private var text: String
    @FocusState private var isWriting: Bool

    init(draft: NoteDraft, save: @escaping (String) -> Void, cancel: @escaping () -> Void) {
        self.draft = draft
        self.save = save
        self.cancel = cancel
        _text = State(initialValue: draft.text)
    }

    /// Whether Save does something: a new note with something written, or a note whose text changed.
    private var canSave: Bool {
        draft.existing == nil ? !ShapeGeometry.committedText(text).isEmpty : text != draft.text
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($isWriting)
                .scrollContentBackground(.hidden)
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(Strings.notePlaceholder)
                            .foregroundStyle(.tertiary)
                            // Where the editor's own first line starts.
                            .padding(.top, 8)
                            .padding(.leading, 5)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .padding(.horizontal, 16)
                .accessibilityLabel(Strings.noteTitle)
                .accessibilityIdentifier("noteText")
                // A document scene puts its Back button on every navigation bar inside it (see
                // `PasswordSheet`): here it would leave what was written without saying so. Cancel and
                // Save are the ways out.
                .navigationBarBackButtonHidden(true)
                .navigationTitle(Strings.noteTitle)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(Strings.cancel, action: cancel)
                            .accessibilityIdentifier("noteCancelButton")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(Strings.save) { save(text) }
                            .disabled(!canSave)
                            .accessibilityIdentifier("noteSaveButton")
                    }
                }
                .onAppear { isWriting = true }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(text != draft.text)
    }
}
