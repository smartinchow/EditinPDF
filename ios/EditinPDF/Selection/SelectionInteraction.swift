import EditinPDFCore
import UIKit

/// The reader's side of text selection on the pages: a long press selects the word under the finger,
/// two handles at the ends of the selection are dragged to extend it, a tap elsewhere ends it, and an
/// edit menu over the selection copies the text.
///
/// It belongs to a `PageScrollViewController`, which keeps it informed (the selection to show, the
/// scrolling and zooming that move it) and tells it where things are on the page (`pageLocation(of:)`,
/// `scrollViewRect(of:onPage:)`, `screenScale(ofPage:)`); it asks the document model's
/// `SelectionController` for the selecting itself. What is drawn, the boxes over the text, is the
/// page views' overlays' job and not this one's: the handles and the menu are what is here.
///
/// The gestures:
/// - **Long press** (0.4 s) on the content view, which is where touches on the pages land (the
///   overlays take none). It has to begin before the scroll view's pan does, and the scroll view's own
///   rules for two recognizers that want the same touch decide that: a finger that moves first
///   scrolls, one that holds still for 0.4 s selects, and after that the touch does not scroll. It is
///   off while a Markup tool that annotates is picked: that tool has the finger (`MarkupInteraction`).
/// - **Tap** on the content view, only while there is a selection: on the selected text it brings the
///   menu back, anywhere else it ends the selection.
/// - **Pan** on each handle. The scroll view's pan waits for it to fail, so that a drag that began on
///   a handle never scrolls, and scrolling is switched off for as long as the handle is held as well.
///   A handle is dragged as a finger drags it: the point the selection goes to is where the handle's
///   own end of the text was, moved as far as the finger has moved since it went down, so the text
///   that is chosen is under the line of the handle and not under the finger, which is below it.
///
/// The handles are subviews of the scroll view, above the content, in the scroll view's own
/// coordinates: they scroll with the pages by themselves, and are put in place again, at the same size,
/// when the zoom or the layout changes. The menu is presented once the finger is up, anchored on the
/// selection, and is dismissed when the reader scrolls or zooms. It offers Copy, and Highlight, Underline
/// and Strikethrough when the document may be marked.
@MainActor
final class SelectionInteraction: NSObject {
    typealias Edge = SelectionHandleView.Edge

    /// How long a finger holds still on a page before it selects a word.
    static let longPressDuration: TimeInterval = 0.4

    /// How far outside the selected text, in PDF points, a tap still counts as on it.
    static let tapSlop: CGFloat = 4

    let startHandle = SelectionHandleView(edge: .start)
    let endHandle = SelectionHandleView(edge: .end)
    let longPress = UILongPressGestureRecognizer()
    let tap = UITapGestureRecognizer()

    private weak var host: PageScrollViewController?
    private lazy var menu = UIEditMenuInteraction(delegate: self)
    private var drag: Drag?

    /// A handle being dragged.
    private struct Drag {
        let edge: Edge
        let page: Int
        /// Where the handle's end of the text was when the drag began, in PDF points of its page.
        let hotSpot: CGPoint
        /// Where the finger went down, in the scroll view's coordinates.
        let touchStart: CGPoint
    }

    init(host: PageScrollViewController) {
        self.host = host
        super.init()
    }

    /// Puts the gesture recognizers, the handles and the menu where they belong in the host's views.
    func install() {
        guard let host else { return }
        longPress.minimumPressDuration = Self.longPressDuration
        longPress.addTarget(self, action: #selector(longPressChanged(_:)))
        longPress.delegate = self
        tap.addTarget(self, action: #selector(tapped(_:)))
        tap.delegate = self
        host.contentView.addGestureRecognizer(longPress)
        host.contentView.addGestureRecognizer(tap)

        startHandle.sibling = endHandle
        endHandle.sibling = startHandle
        for handle in [startHandle, endHandle] {
            let pan = HandlePanGestureRecognizer(target: self, action: #selector(handleDragged(_:)))
            pan.referenceView = host.scrollView
            pan.maximumNumberOfTouches = 1
            pan.delegate = self
            handle.addGestureRecognizer(pan)
            host.scrollView.panGestureRecognizer.require(toFail: pan)
            host.scrollView.addSubview(handle)
        }
        host.scrollView.addInteraction(menu)
    }

    /// Whether a handle is being dragged.
    var isDraggingHandle: Bool { drag != nil }

    // MARK: Long press

    @objc private func longPressChanged(_ recognizer: UILongPressGestureRecognizer) {
        guard let host else { return }
        switch recognizer.state {
        case .began:
            beginWord(atContentPoint: recognizer.location(in: host.contentView))
        case .ended, .cancelled, .failed:
            presentMenuIfIdle()
        default:
            break
        }
    }

    /// Selects the word at `point`, in the content view's coordinates (layout points at zoom 1): the
    /// press of a finger that has held still. Nothing happens off the pages.
    func beginWord(atContentPoint point: CGPoint) {
        guard let host, let controller = host.model.selection, let location = host.pageLocation(of: point) else { return }
        menu.dismissMenu()
        controller.beginWord(page: location.page, at: location.point)
    }

    // MARK: Tap

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, let host else { return }
        tap(atContentPoint: recognizer.location(in: host.contentView))
    }

    /// A tap at `point`, in the content view's coordinates: on the selected text it shows the menu
    /// again, anywhere else it ends the selection.
    func tap(atContentPoint point: CGPoint) {
        guard let host, let controller = host.model.selection, let selection = host.selection else { return }
        if let location = host.pageLocation(of: point), location.page == selection.page,
           selection.rects.contains(where: { $0.insetBy(dx: -Self.tapSlop, dy: -Self.tapSlop).contains(location.point) }) {
            presentMenu()
        } else {
            controller.clear()
            menu.dismissMenu()
        }
    }

    // MARK: Handles

    @objc private func handleDragged(_ recognizer: HandlePanGestureRecognizer) {
        guard let host, let handle = recognizer.view as? SelectionHandleView else { return }
        let location = recognizer.location(in: host.scrollView)
        switch recognizer.state {
        case .began:
            beginDrag(of: handle.edge, touchAt: recognizer.initialLocation)
            updateDrag(touchAt: location)
        case .changed:
            updateDrag(touchAt: location)
        case .ended, .cancelled, .failed:
            endDrag()
        default:
            break
        }
    }

    /// The finger went down on the handle at `edge`, at `start` in the scroll view's coordinates. Scrolling
    /// is switched off until `endDrag()`, so that the page does not move under the handle.
    func beginDrag(of edge: Edge, touchAt start: CGPoint) {
        guard let host, let controller = host.model.selection, let selection = host.selection,
              let box = edge == .start ? selection.rects.first : selection.rects.last else { return }
        let hotSpot = CGPoint(x: edge == .start ? box.minX : box.maxX, y: box.midY)
        drag = Drag(edge: edge, page: selection.page, hotSpot: hotSpot, touchStart: start)
        controller.beginExtending(edge)
        host.scrollView.isScrollEnabled = false
        menu.dismissMenu()
    }

    /// The finger is at `location` in the scroll view's coordinates: the selection goes to where the
    /// handle's end of the text would be if it had moved as far as the finger.
    func updateDrag(touchAt location: CGPoint) {
        guard let host, let drag, let controller = host.model.selection else { return }
        let scale = host.screenScale(ofPage: drag.page)
        guard scale > 0 else { return }
        controller.extend(to: CGPoint(x: drag.hotSpot.x + (location.x - drag.touchStart.x) / scale,
                                      y: drag.hotSpot.y + (location.y - drag.touchStart.y) / scale))
    }

    /// The finger came up, or the drag was cancelled: scrolling is back, and so is the menu.
    func endDrag() {
        guard drag != nil else { return }
        drag = nil
        host?.scrollView.isScrollEnabled = true
        presentMenuIfIdle()
    }

    // MARK: Following the host

    /// The host's selection changed: the handles go to its ends, and the menu goes with the selection.
    func selectionDidChange() {
        layoutHandles()
        guard let host else { return }
        if host.selection == nil {
            menu.dismissMenu()
            // A drag whose selection has gone has nothing to move.
            if drag != nil {
                drag = nil
                host.scrollView.isScrollEnabled = true
            }
        } else {
            presentMenuIfIdle()
        }
    }

    /// The reader is about to scroll or zoom: the menu would be left behind, so it goes.
    func viewportWillChange() {
        menu.dismissMenu()
    }

    /// The pages are about to be laid out again for a new width (the device turning, an iPhone Duo
    /// folding or unfolding, Split View): the menu would point at where the text was, so it goes, and a
    /// handle being dragged is let go of, since the finger's way from where it went down no longer
    /// means the same distance on the page. The selection stays; the layout puts the handles at its new
    /// place, and a tap on it brings the menu back.
    func layoutWillChange() {
        menu.dismissMenu()
        guard drag != nil else { return }
        drag = nil
        host?.scrollView.isScrollEnabled = true
    }

    /// Puts the handles at the ends of the selection, in the scroll view's coordinates, or hides them
    /// when there is no selection or no layout to find it in. Called whenever something that moves the
    /// selection on screen changes: the zoom, the layout, the selection itself.
    func layoutHandles() {
        guard let host, let selection = host.selection, let first = selection.rects.first, let last = selection.rects.last,
              let startBox = host.scrollViewRect(of: first, onPage: selection.page),
              let endBox = host.scrollViewRect(of: last, onPage: selection.page) else {
            startHandle.isHidden = true
            endHandle.isHidden = true
            return
        }
        startHandle.place(top: CGPoint(x: startBox.minX, y: startBox.minY), bottom: CGPoint(x: startBox.minX, y: startBox.maxY))
        endHandle.place(top: CGPoint(x: endBox.maxX, y: endBox.minY), bottom: CGPoint(x: endBox.maxX, y: endBox.maxY))
        startHandle.isHidden = false
        endHandle.isHidden = false
    }

    // MARK: Menu

    /// Whether nothing is going on that the menu would be in the way of: no finger on a handle or held
    /// for a selection, and no scrolling or zooming.
    private var isIdle: Bool {
        guard let host else { return false }
        let scrollView = host.scrollView
        // A Markup tool's drag selects as it goes, and marks (and so ends) the selection at its end.
        return drag == nil && !host.markupInteraction.isMarking && longPress.state != .began && longPress.state != .changed
            && !scrollView.isDragging && !scrollView.isZooming && !scrollView.isDecelerating
    }

    private func presentMenuIfIdle() {
        guard isIdle, host?.selection != nil else { return }
        presentMenu()
    }

    /// Shows the menu over the selection, when some of it is on screen.
    func presentMenu() {
        guard let target = menuTarget() else { return }
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: target.midX, y: target.minY)))
    }

    /// The part of the selection that is on screen, in the scroll view's coordinates: what the menu
    /// points at. Nil when none of it is.
    private func menuTarget() -> CGRect? {
        guard let host, let selection = host.selection else { return nil }
        let boxes = selection.rects.compactMap { host.scrollViewRect(of: $0, onPage: selection.page) }
        guard let first = boxes.first else { return nil }
        let all = boxes.dropFirst().reduce(first) { $0.union($1) }
        let visible = host.scrollView.bounds.inset(by: host.scrollView.adjustedContentInset)
        let shown = all.intersection(visible)
        return shown.isNull || shown.isEmpty ? nil : shown
    }

    /// Puts the selected text on the pasteboard: what the menu's item does.
    func copySelection() {
        host?.model.selection?.copySelection()
    }

    /// Marks the selected text with `kind`: what the menu's Highlight, Underline and Strikethrough do.
    /// Says whether the mark was made.
    @discardableResult
    func mark(_ kind: MarkupKind) async -> Bool {
        await host?.model.markSelection(kind) ?? false
    }

    /// The marks the menu offers: those whose tool may be used on the selection's page (none before
    /// the document's permissions are read).
    private func offeredMarks() -> [MarkupKind] {
        guard let model = host?.model, model.capabilities != nil else { return [] }
        let page = host?.selection?.page ?? model.currentPage
        return [MarkupKind.highlight, .underline, .strikeOut].filter { model.refusal(of: Tool(markupKind: $0), onPage: page) == nil }
    }

    /// Whether a finger held still at `point` (the content view's coordinates) may select the word
    /// there: on a page, and not while a Markup tool that annotates is picked, which has the finger.
    func isLongPressAllowed(atContentPoint point: CGPoint) -> Bool {
        guard let host, host.model.selection != nil else { return false }
        if let tool = host.model.tool, tool.annotates { return false }
        return host.pageLocation(of: point) != nil
    }
}

// MARK: - UIGestureRecognizerDelegate

extension SelectionInteraction: UIGestureRecognizerDelegate {
    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard let host else { return false }
        if gestureRecognizer === longPress {
            // On a page, and not in the gap between two; not while a Markup tool has the finger.
            return isLongPressAllowed(atContentPoint: longPress.location(in: host.contentView))
        }
        // The tap and the handles' pans have nothing to do without a selection.
        return host.selection != nil
    }
}

// MARK: - UIEditMenuInteractionDelegate

// The SDK does not say that the delegate's methods are called on the main actor, though UIKit only
// ever calls them there (the menu is presented from, and answers to, the main thread): `@preconcurrency`
// makes the compiler check it when they are called, instead of taking it on trust.
extension SelectionInteraction: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        let copy = UIAction(title: Strings.copy) { [weak self] _ in self?.copySelection() }
        let marks = offeredMarks().map { kind in
            let tool = Tool(markupKind: kind)
            return UIAction(title: tool.title, image: UIImage(systemName: tool.systemImage)) { [weak self] _ in
                Task { await self?.mark(kind) }
            }
        }
        return UIMenu(children: [copy] + marks)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        menuTarget() ?? .zero
    }
}
