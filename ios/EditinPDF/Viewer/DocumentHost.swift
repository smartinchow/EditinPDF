import SwiftUI
import UIKit

/// What the document screen needs of the view controller SwiftUI's document scene shows it in (a
/// `UIDocumentViewController`): the scene's document, for Save to write through (`writer`), the line
/// under the document's name, which says "Edited" while there is something to save (`showEdited`), and the
/// navigation bar's own back button, whose action it takes over (`interceptBack`) so that Back with
/// unsaved changes asks first (`DocumentScreen.goBack`), and which it closes the document with once the
/// reader has chosen (`close`).
///
/// The back button stays the system's: its look, its name ("Back" or the document browser's), its
/// identifier (`BackButton`), its reach by VoiceOver, Full Keyboard Access and the pointer. Only the
/// action its navigation item runs (`UINavigationItem.backAction`) is ours, and that action runs the
/// system's own (`close`) once the reader has chosen. The document's controller is the only one in its
/// navigation stack, so there is no edge swipe that pops it past the question (observed on the iOS 26.5
/// and 27.0 simulators).
///
/// Found from the screen's view controllers (`DocumentHostAnchor`) once they are in the window, and
/// looked at again on every update of the screen: SwiftUI may give the navigation item a new back
/// action of its own, which is taken over again. Where there is no such controller or action (a system
/// that shows the document otherwise), Back is the system's, and closes without asking; the recovery
/// copy then keeps the changes, offered when the document opens again (`DocumentScreen`).
@MainActor
final class DocumentHost {
    /// The view controller the scene shows the document in, held weakly: the scene owns it.
    private(set) weak var controller: UIDocumentViewController?
    /// The system's back action, run to close the document (`close`).
    private var systemBack: UIAction?
    /// Writes through the scene's document, for Save (`DocumentModel.fileWriter`, which holds it weakly).
    private(set) var writer: SceneDocumentWriter?
    /// What the back button does: set by the screen.
    var goBack: (() -> Void)?

    /// The identifier of the back action that is ours.
    static let backIdentifier = UIAction.Identifier("app.editinpdf.back")

    /// Finds the document's view controller up the responder chain from `responder`, and takes over its
    /// back button.
    func attach(from responder: UIResponder) {
        var current: UIResponder? = responder
        while let next = current, !(next is UIDocumentViewController) { current = next.next }
        guard let found = current as? UIDocumentViewController else { return }
        if controller !== found {
            controller = found
            systemBack = nil
            writer = found.document.map(SceneDocumentWriter.init(document:))
        }
        interceptBack()
    }

    /// Makes the back button run `goBack`, keeping the system's action to close with. Does nothing when
    /// it does already, or when the navigation item has no back action of the system's.
    func interceptBack() {
        guard let item = controller?.navigationItem, let current = item.backAction,
              current.identifier != Self.backIdentifier else { return }
        systemBack = current
        item.backAction = UIAction(title: current.title, image: current.image, identifier: Self.backIdentifier) { [weak self] _ in
            self?.goBack?()
        }
    }

    /// Says "Edited" under the document's name in the navigation bar while it has something to save
    /// (iOS 26 and later, where the bar has a line for it; the page indicator says it before).
    func showEdited(_ edited: Bool) {
        guard #available(iOS 26, *), let item = controller?.navigationItem else { return }
        let subtitle = edited ? Strings.edited : nil
        if item.subtitle != subtitle { item.subtitle = subtitle }
    }

    /// Whether the back button runs `goBack`.
    var interceptsBack: Bool {
        systemBack != nil && controller?.navigationItem.backAction?.identifier == Self.backIdentifier
    }

    /// Closes the document as the system's back button does, back to the documents. False when there is
    /// no system action to run.
    @discardableResult
    func close() -> Bool {
        guard let systemBack else { return false }
        // `UIControl.sendAction(_:)` runs an action's handler, as a tap on a control holding it would.
        UIButton(type: .system).sendAction(systemBack)
        return true
    }
}

/// A view controller with nothing to show, in the screen's hierarchy, that finds the document's view
/// controller for `host` once it is in the window, and on every update of the screen.
struct DocumentHostAnchor: UIViewControllerRepresentable {
    let host: DocumentHost
    /// Whether the document has something to save: "Edited" is shown under its name meanwhile. Read so
    /// that the anchor is updated (and the back action looked at again) as it changes.
    let needsSave: Bool

    func makeUIViewController(context: Context) -> AnchorController {
        AnchorController(host: host)
    }

    func updateUIViewController(_ controller: AnchorController, context: Context) {
        controller.host = host
        controller.needsSave = needsSave
        if controller.view.window != nil {
            host.attach(from: controller)
            host.showEdited(needsSave)
        }
    }

    /// Attaches its host as it appears.
    final class AnchorController: UIViewController {
        var host: DocumentHost
        var needsSave = false

        init(host: DocumentHost) {
            self.host = host
            super.init(nibName: nil, bundle: nil)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func loadView() {
            let view = UIView()
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            host.attach(from: self)
            host.showEdited(needsSave)
        }
    }
}
