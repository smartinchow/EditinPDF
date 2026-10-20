import EditinPDFCore
import SwiftUI

/// The sheet where several options of a list box are checked (`DocumentModel.choiceDraft`): a tap on
/// an option checks or unchecks it; Done fills the field with what is checked, once, as one change;
/// Cancel leaves it as it was. While what is checked differs from what the field has, a swipe does not
/// put the sheet away: Cancel does, on purpose.
struct ChoiceSheet: View {
    let draft: ChoiceDraft
    /// Fills the field with the export values checked (the model puts the sheet away).
    let save: (Set<String>) async -> Void
    /// Closes the sheet; nothing changes.
    let cancel: () -> Void

    @State private var checked: Set<String>
    @State private var isSaving = false

    init(draft: ChoiceDraft, save: @escaping (Set<String>) async -> Void, cancel: @escaping () -> Void) {
        self.draft = draft
        self.save = save
        self.cancel = cancel
        _checked = State(initialValue: Set(draft.selected))
    }

    var body: some View {
        NavigationStack {
            List {
                Section(draft.title) {
                    ForEach(Array(draft.options.enumerated()), id: \.offset) { index, option in
                        row(option, index: index)
                    }
                }
            }
            // A document scene puts its Back button on every navigation bar inside it (see
            // `PasswordSheet`): Cancel and Done are the ways out.
            .navigationBarBackButtonHidden(true)
            .navigationTitle(Strings.chooseOption)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.cancel, action: cancel)
                        .accessibilityIdentifier("choiceCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.done) {
                        isSaving = true
                        Task {
                            await save(checked)
                            isSaving = false
                        }
                    }
                    .disabled(isSaving)
                    .accessibilityIdentifier("choiceDoneButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .interactiveDismissDisabled(checked != Set(draft.selected))
    }

    /// One option: what it shows, checked or not; a tap checks or unchecks it.
    private func row(_ option: ChoiceOption, index: Int) -> some View {
        let isChecked = checked.contains(option.export)
        return Button {
            if isChecked { checked.remove(option.export) } else { checked.insert(option.export) }
        } label: {
            HStack {
                Text(option.display.isEmpty ? option.export : option.display)
                    .foregroundStyle(.primary)
                Spacer()
                if isChecked {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.tint)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
        }
        .accessibilityAddTraits(isChecked ? .isSelected : [])
        .accessibilityIdentifier("choiceOption-\(index)")
    }
}
