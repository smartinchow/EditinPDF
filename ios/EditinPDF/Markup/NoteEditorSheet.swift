import SwiftUI

/// The sheet a note is written and read in (`DocumentModel.noteDraft`): its text, Save and Cancel.
/// For a new note, Save is there once something other than spaces is written; for a note on the page,
/// once its text is changed. While the text differs from what the sheet opened with, a swipe does not
/// put the sheet away (and what was written with it): Cancel does, on purpose. Save puts it away once
/// the note is saved; a save that is refused leaves it up, with what was written, and says why here,
/// over the sheet (`failure`).
///
/// What is written is held to the most a note takes (`ShapeGeometry.maxTextLength`): what goes past it
/// is let go of, so a save is never refused for it.
///
/// The text is the reader's, and is never logged.
struct NoteEditorSheet: View {
    let draft: NoteDraft
    /// Why a change was not made, for the sheet to show while it is up (the screen's own alert waits).
    @Binding var failure: EditFailure?
    /// Saves the text written (the model adds or changes the note, and puts the sheet away once it has).
    let save: (String) async -> Void
    /// Closes the sheet; nothing changes.
    let cancel: () -> Void

    @State private var text: String
    @State private var isSaving = false
    @FocusState private var isWriting: Bool

    init(draft: NoteDraft, failure: Binding<EditFailure?>, save: @escaping (String) async -> Void, cancel: @escaping () -> Void) {
        self.draft = draft
        _failure = failure
        self.save = save
        self.cancel = cancel
        _text = State(initialValue: draft.text)
    }

    /// Whether the alert about a refused save is up: while there is a failure to show.
    private var showsFailure: Binding<Bool> {
        Binding(get: { failure != nil }, set: { isShown in if !isShown { failure = nil } })
    }

    /// Whether Save does something: a new note with something written, or a note whose text changed.
    private var canSave: Bool {
        draft.existing == nil ? !ShapeGeometry.committedText(text).isEmpty : text != draft.text
    }

    var body: some View {
        NavigationStack {
            TextEditor(text: $text)
                .focused($isWriting)
                .onChange(of: text) { _, written in
                    let limited = ShapeGeometry.limitedText(written)
                    if limited != written { text = limited }
                }
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
                        Button(Strings.save) {
                            isSaving = true
                            Task {
                                await save(ShapeGeometry.limitedText(text))
                                isSaving = false
                            }
                        }
                        .disabled(!canSave || isSaving)
                            .accessibilityIdentifier("noteSaveButton")
                    }
                }
                .onAppear { isWriting = true }
                // A save refused: why, over the sheet, which stays with what was written.
                .alert(failure?.title ?? "", isPresented: showsFailure, presenting: failure) { _ in
                } message: { failure in
                    if !failure.message.isEmpty { Text(failure.message) }
                }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(text != draft.text)
    }
}
