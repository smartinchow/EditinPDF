import SwiftUI
import UIKit
import os

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
/// action of its own, which is taken over again.
///
/// The scene shows each document it opens in the same view controller, its navigation item and back
/// action left as the last document's screen left them (observed on the iOS 26.5 and 27.0 simulators: a
/// second document opened in the same run of the app came up in the first one's controller, its back
/// action still the one the first screen put there). So the system's action is kept with each action of
/// ours (`systemBacks`), for the next screen to find under it, and a screen gives the navigation item back
/// as it found it as it goes (`detach`).
///
/// How the document is saved is decided (`decide`) as soon as the controller, its document and its back
/// action are all found: `SavingMode.explicit`. Only when they are still not all there a moment after the
/// screen appeared (`fallbackDelay`: a system that shows the document otherwise) is it saved the system's
/// way instead (`SavingMode.automatic`): Back is the system's and the changes are saved as it closes, as
/// before the reader could choose, so that a reader is never left unable to save. A DEBUG build logs why.
@MainActor
final class DocumentHost {
    /// The view controller the scene shows the document in, held weakly: the scene owns it.
    private(set) weak var controller: UIDocumentViewController?
    /// The system's back action, run to close the document (`close`).
    private var systemBack: UIAction?
    /// The back action of ours on the navigation item (`interceptBack`): the item's own copy of it, held by
    /// the item, to give the item back as it was (`detach`) only while it is still there.
    private weak var ownBack: UIAction?
    /// Writes through the scene's document, for Save (`DocumentModel.fileWriter`, which holds it weakly).
    private(set) var writer: SceneDocumentWriter?
    /// What the back button does: set by the screen.
    var goBack: (() -> Void)?
    /// Hears how the document is to be saved, once it is decided (`decide`); a decision made before it is
    /// set is handed over as it is set.
    var onDecided: ((SavingMode) -> Void)? {
        didSet { if let decided, let onDecided { onDecided(decided) } }
    }
    /// The decision, once made.
    private(set) var decided: SavingMode?
    /// Whether the screen has appeared, so that the decision is due (`decide`).
    private var decisionDue = false
    /// Whether "Edited" is to be shown (`showEdited`).
    private var edited = false
    /// Watches the navigation item: the document's view controller sets its own line under the name and
    /// its back action again as it updates its navigation item (seen as a document opens on the iPad), and
    /// ours are put back then.
    private var watches: [NSKeyValueObservation] = []
    /// Whether the screen has gone (`detach`): nothing is attached, watched or decided until it appears
    /// again (`resume`).
    private var detached = false

    /// The identifier of the back action that is ours.
    static let backIdentifier = UIAction.Identifier("app.editinpdf.back")
    /// How long after the screen appears the controller, its document and its back action may still be
    /// found before the document is saved the system's way (`decide`).
    static let fallbackDelay: Duration = .seconds(2)

    /// The system's back action under each action of ours (the navigation item's copy), held as long as
    /// ours is: a navigation item a screen left with ours on it (the scene reuses the view controller for
    /// the next document) still leads the next screen to the system's. Keyed by identity: actions that
    /// look alike are equal.
    private static let systemBacks = NSMapTable<UIAction, UIAction>(keyOptions: [.weakMemory, .objectPointerPersonality],
                                                                    valueOptions: .strongMemory)

    #if DEBUG
    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "host")
    #endif

    /// Finds the document's view controller up the responder chain from `responder`, and takes over its
    /// back button.
    func attach(from responder: UIResponder) {
        guard !detached else { return }
        var current: UIResponder? = responder
        while let next = current, !(next is UIDocumentViewController) { current = next.next }
        guard let found = current as? UIDocumentViewController else { return }
        if controller !== found {
            controller = found
            systemBack = nil
            ownBack = nil
            watch(found.navigationItem)
        }
        // The scene's document, as it is now (never one kept from before).
        if writer?.document !== found.document {
            writer = found.document.map(SceneDocumentWriter.init(document:))
        }
        interceptBack()
        applyEdited()
        decideOnceFound()
    }

    /// Puts the back action and the line under the name back whenever the navigation item's change.
    private func watch(_ item: UINavigationItem) {
        watches.forEach { $0.invalidate() }
        let reapply: @Sendable () -> Void = { [weak self] in
            Task { @MainActor in self?.reapply() }
        }
        var watches = [item.observe(\.backAction) { _, _ in reapply() }]
        if #available(iOS 26, *) {
            watches.append(item.observe(\.subtitle) { _, _ in reapply() })
        }
        self.watches = watches
    }

    /// Makes the back button run `goBack`, keeping the system's action to close with. Does nothing when
    /// it does already, or when the navigation item has no back action of the system's. An action of ours
    /// another screen left there (the controller reused for this document) is replaced too, the system's
    /// under it taken over.
    func interceptBack() {
        guard let item = controller?.navigationItem, let current = item.backAction, current !== ownBack else { return }
        let system: UIAction
        if current.identifier == Self.backIdentifier {
            guard let under = Self.systemBacks.object(forKey: current) else { return }
            system = under
        } else {
            system = current
        }
        systemBack = system
        let own = UIAction(title: system.title, image: system.image, identifier: Self.backIdentifier) { [weak self] _ in
            self?.goBack?()
        }
        // The item keeps a copy of the action it is given: that copy is the one to know it by.
        item.backAction = own
        let installed = item.backAction ?? own
        Self.systemBacks.setObject(system, forKey: installed)
        ownBack = installed
    }

    /// The screen has appeared: how the document is saved is decided, now when everything is found, or as
    /// soon as it is (`decideOnceFound`), or else, a moment later, the system's way (`fallBack`).
    func decide() {
        guard decided == nil, !detached, !decisionDue else { return }
        decisionDue = true
        decideOnceFound()
        guard decided == nil else { return }
        Task { [weak self] in
            try? await Task.sleep(for: Self.fallbackDelay)
            self?.fallBack()
        }
    }

    /// Decides `.explicit` once the screen has appeared and the controller, its document and its back
    /// action are all found.
    private func decideOnceFound() {
        guard decisionDue, decided == nil, !detached else { return }
        guard mode == .explicit else { return }
        record(.explicit)
    }

    /// Still not all found a moment after the screen appeared: the document is saved the system's way.
    private func fallBack() {
        guard decided == nil, !detached else { return }
        #if DEBUG
        let controllerFound = controller != nil, documentFound = writer != nil, backActionFound = systemBack != nil
        let backAction = controller?.navigationItem.backAction?.identifier.rawValue ?? "none"
        Self.log.error("""
            saved the system's way: controller found \(controllerFound, privacy: .public), document found \(documentFound, privacy: .public), \
            system back action found \(backActionFound, privacy: .public) (the item's back action: \(backAction, privacy: .public))
            """)
        #endif
        record(mode)
    }

    /// What the controller, its document and its back action found so far allow (`SavingMode.decide`).
    private var mode: SavingMode {
        SavingMode.decide(controllerFound: controller != nil, documentFound: writer != nil, backActionFound: systemBack != nil)
    }

    private func record(_ mode: SavingMode) {
        decided = mode
        onDecided?(mode)
    }

    /// The screen has gone: the navigation item is given back as it was found (the system's back action,
    /// the line under the name without "Edited"), for the next document the scene shows in the same
    /// controller, and nothing of this screen is kept or watched any more. What another screen has put
    /// there since is left alone. Should the screen appear again, it is found again (`resume`).
    func detach() {
        detached = true
        watches.forEach { $0.invalidate() }
        watches = []
        if let item = controller?.navigationItem, let ownBack, item.backAction === ownBack {
            if let systemBack { item.backAction = systemBack }
            if #available(iOS 26, *), item.subtitle == Strings.edited { item.subtitle = nil }
        }
        controller = nil
        systemBack = nil
        ownBack = nil
        writer = nil
        goBack = nil
        onDecided = nil
        edited = false
        if decided == nil { decisionDue = false }
    }

    /// The screen appears (again): it may be attached.
    func resume() {
        detached = false
    }

    /// Says "Edited" under the document's name in the navigation bar while it has something to save
    /// (iOS 26 and later, where the bar has a line for it; the page indicator says it before). The screen
    /// says it through SwiftUI too (`navigationSubtitle`); this puts it back whenever the document's view
    /// controller sets its navigation item again.
    func showEdited(_ edited: Bool) {
        guard !detached else { return }
        self.edited = edited
        applyEdited()
    }

    private func applyEdited() {
        guard !detached, #available(iOS 26, *), let item = controller?.navigationItem else { return }
        if edited {
            if item.subtitle != Strings.edited { item.subtitle = Strings.edited }
        } else if item.subtitle == Strings.edited {
            item.subtitle = nil
        }
    }

    /// Whether the document is still open and on screen: its document not closed (or closing), its view
    /// controller in a window. (The screen's own disappearance can come late, after the close.)
    var isStillShowingTheDocument: Bool {
        guard let controller, controller.viewIfLoaded?.window != nil else { return false }
        guard let document = controller.document else { return true }
        return !document.documentState.contains(.closed)
    }

    /// Takes the back action over and says "Edited" again, should the navigation item have been set anew;
    /// decides once everything is found.
    func reapply() {
        guard !detached else { return }
        interceptBack()
        applyEdited()
        decideOnceFound()
    }

    /// Whether the back button runs `goBack`.
    var interceptsBack: Bool {
        guard let ownBack else { return false }
        return systemBack != nil && controller?.navigationItem.backAction === ownBack
    }

    /// Closes the document as the system's back button does, back to the documents. False when there is
    /// no system action to run.
    @discardableResult
    func close() -> Bool {
        guard let systemBack else { return false }
        #if DEBUG
        // For a UI test: the system's back action doing nothing, to see the screen close another way.
        if ProcessInfo.processInfo.arguments.contains(FixtureStaging.systemCloseDoesNothingArgument) { return true }
        #endif
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
    /// What the toolbar shows (text selected, the tool picked, the width): SwiftUI sets the navigation item
    /// again as the toolbar changes, and the back action and "Edited" are looked at again then.
    let toolbarState: String

    func makeUIViewController(context: Context) -> AnchorController {
        AnchorController(host: host)
    }

    func updateUIViewController(_ controller: AnchorController, context: Context) {
        controller.host = host
        controller.needsSave = needsSave
        controller.toolbarState = toolbarState
        if controller.view.window != nil {
            host.attach(from: controller)
            host.showEdited(needsSave)
            // And once SwiftUI has applied this update's toolbar to the navigation item.
            let host = host
            DispatchQueue.main.async { host.reapply() }
        }
    }

    /// Attaches its host as it appears.
    final class AnchorController: UIViewController {
        var host: DocumentHost
        var needsSave = false
        var toolbarState = ""

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
            host.decide()
        }
    }
}
