import UIKit

/// The app's delegate, for the one thing SwiftUI's commands cannot do: the File menu's Close (⌘W). The
/// system's closes the document at once (`performClose:` to the document's view controller), past the
/// question Back asks; here it is Back's (`FrontDocument.close`), which asks first when there is something
/// to save. Where no document is in front (the document browser), the menu's Close is off.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    /// The action of the File menu's Close: performClose:, the system's.
    static let systemClose = NSSelectorFromString("performClose:")

    override func buildMenu(with builder: any UIMenuBuilder) {
        super.buildMenu(with: builder)
        guard builder.system == .main else { return }
        builder.replaceChildren(ofMenu: .close) { children in
            children.map { element in
                guard let command = element as? UIKeyCommand, command.action == Self.systemClose else { return element }
                return UIKeyCommand(title: Strings.closeDocument, action: #selector(closeDocument(_:)),
                                    input: command.input ?? "w", modifierFlags: command.modifierFlags)
            }
        }
    }

    @MainActor @objc func closeDocument(_ sender: Any?) {
        FrontDocument.shared.close()
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(closeDocument(_:)) {
            return MainActor.assumeIsolated { FrontDocument.shared.model?.closeRequested != nil }
        }
        return super.canPerformAction(action, withSender: sender)
    }
}
