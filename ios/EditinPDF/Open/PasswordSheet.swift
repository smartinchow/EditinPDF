import SwiftUI

/// The prompt for the password of a protected document: a field, Unlock to try what was typed, and
/// Cancel to put the prompt away. A refused password says so, empties the field and leaves the
/// keyboard up for the next try.
///
/// It cannot be swiped away, so that a stray swipe does not lose what was typed: the ways out are
/// Unlock, which opens the document and takes the prompt away with it, and Cancel. Cancel leaves the
/// document locked, and its screen (`DocumentScreen`) offers to enter the password again; the system's
/// own way out of the document is there, on every iOS version, once the prompt is out of the way.
struct PasswordSheet: View {
    let model: DocumentModel
    /// Puts the prompt away. Passed in by the screen that presents it, which owns whether it is up.
    let cancel: () -> Void

    @State private var password = ""
    /// True from Unlock being pressed until the engine has answered.
    @State private var isUnlocking = false
    @FocusState private var fieldIsFocused: Bool

    /// Whether a password has been tried and refused.
    private var wasRefused: Bool {
        if case .locked(_, let wrongPassword) = model.state { return wrongPassword }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField(Strings.passwordPlaceholder, text: $password)
                        .focused($fieldIsFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        // The keyboard's own key does what Unlock does.
                        .onSubmit(unlock)
                        .accessibilityIdentifier("passwordField")
                } header: {
                    Text(Strings.passwordExplanation)
                        .textCase(nil)
                } footer: {
                    // Gone while the next try is under way, back if that one is refused too.
                    if wasRefused && !isUnlocking {
                        Text(Strings.wrongPassword)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("wrongPasswordLabel")
                    }
                }
            }
            // A document scene puts its Back button on every navigation bar inside it (as in the
            // search and thumbnails sheets); here it would close the prompt without opening the
            // document, and Cancel is the way out.
            .navigationBarBackButtonHidden(true)
            .navigationTitle(Strings.passwordTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.cancel, action: cancel)
                        .accessibilityIdentifier("cancelUnlockButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: unlock) {
                        if isUnlocking {
                            ProgressView()
                        } else {
                            Text(Strings.unlock)
                        }
                    }
                    .disabled(password.isEmpty || isUnlocking)
                    .accessibilityLabel(Strings.unlock)
                    .accessibilityIdentifier("unlockButton")
                }
            }
        }
        .interactiveDismissDisabled()
        // The keyboard comes up with the prompt: the field is the only thing to do here.
        .task {
            await Task.yield()
            fieldIsFocused = true
        }
    }

    /// Tries the password typed. The engine's open runs off the main actor (the model sees to
    /// that), so the prompt stays alive, showing progress, while it works. The password is not kept
    /// once it has been tried: if the document does not open it was refused (the model says so, and
    /// the field is ready to be typed again), and if it does the prompt is on its way out.
    private func unlock() {
        guard !password.isEmpty, !isUnlocking else { return }
        isUnlocking = true
        let attempt = password
        Task {
            let opened = await model.unlock(password: attempt)
            isUnlocking = false
            password = ""
            guard !opened else { return }
            fieldIsFocused = true
            AccessibilityNotification.Announcement(Strings.wrongPassword).post()
        }
    }
}
