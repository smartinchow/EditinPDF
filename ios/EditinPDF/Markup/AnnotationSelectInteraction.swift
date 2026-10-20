import EditinPDFCore
import UIKit

/// What the menu over a selected annotation offers.
enum AnnotationAction: Equatable {
    /// Change its text: a note's in the note sheet, a text box's in the box to type in.
    case edit
    case delete
}

/// **Select**: picking an annotation already on a page, dragging it somewhere else, and the menu over
/// it (Edit, Delete). It belongs to the scroll view's `MarkupInteraction`, which routes its tap and its
/// one-finger pan here and hands it the tool's changes and the layout's. What is selected is the
/// model's (`DocumentModel.selectedAnnotation`); the scroll view outlines it on its page
/// (`PageOverlayView.selectedAnnotationRect`) and says when it changes (`selectionDidChange`).
///
/// - A tap on an annotation selects the one on top under the finger, within
///   `MarkupInteraction.screenHitSlop` points on screen, and the menu comes up over it; a tap anywhere
///   else lets go. While text is selected a tap is the text selection's: it ends that first.
/// - One finger that goes down on the selected annotation, when it may be moved
///   (`DocumentModel.canChange`), drags it: the outline follows the finger
///   (`PageOverlayView.dragOffset`), kept to the page, and the move is handed over when the finger comes
///   up, worked out against the revision the drag began at. A move refused (stale, behind a turn of its
///   page, say) leaves nothing where it was dropped. Anywhere else one finger scrolls; two fingers
///   always scroll and zoom (the pan fails on a second finger: `MarkupPanGestureRecognizer`).
/// - The menu offers Edit for a note (the note sheet) and for a text box on an upright page (the box
///   to type in, over it, with its text: `TextBoxInteraction.beginEditing`), and Delete for one the
///   file does not lock; nothing while the document forbids markup.
@MainActor
final class AnnotationSelectInteraction: NSObject {
    private weak var host: PageScrollViewController?
    private let model: DocumentModel
    private let textBoxes: TextBoxInteraction
    private lazy var menu = UIEditMenuInteraction(delegate: self)

    /// The selected annotation being dragged: which, on what page, where the finger went down (view
    /// space), its box and its page's size when the drag began, the revision the move is worked out
    /// against, and how far it has been dragged.
    private struct Move {
        let ref: AnnotationRef
        let start: CGPoint
        let box: CGRect
        let pageSize: CGSize
        let revision: UInt64
        var offset: CGSize = .zero
    }
    private var moving: Move?

    init(host: PageScrollViewController, model: DocumentModel, textBoxes: TextBoxInteraction) {
        self.host = host
        self.model = model
        self.textBoxes = textBoxes
        super.init()
    }

    /// Puts the menu on the scroll view.
    func install() {
        host?.scrollView.addInteraction(menu)
    }

    /// Whether the selected annotation is being dragged.
    var isMoving: Bool { moving != nil }

    /// How far outside an annotation's box a touch on `page` still lands on it: the same on screen at
    /// every zoom.
    private func hitSlop(onPage page: Int) -> CGFloat {
        MarkupInteraction.hitSlop(screenScale: host?.screenScale(ofPage: page) ?? 0)
    }

    // MARK: The tap

    /// Whether a tap at `point` (the content view's coordinates) is Select's: Select is picked, no text
    /// is selected, and an annotation is under it or one is selected (the tap lets go of it).
    func takesTap(atContentPoint point: CGPoint) -> Bool {
        guard model.tool == .select, let host, host.selection == nil else { return false }
        if model.selectedAnnotation != nil { return true }
        guard let location = host.pageLocation(of: point) else { return false }
        return model.annotationIndex.hit(page: location.page, at: location.point, slop: hitSlop(onPage: location.page)) != nil
    }

    /// A tap at `point` with Select picked: the annotation on top under it is selected, or none; a tap
    /// on the one selected already brings its menu back. Says whether the tap was Select's.
    @discardableResult
    func tap(atContentPoint point: CGPoint) -> Bool {
        guard model.tool == .select, let host else { return false }
        let before = model.selectedAnnotation
        if let location = host.pageLocation(of: point) {
            model.selectAnnotation(page: location.page, at: location.point, slop: hitSlop(onPage: location.page))
        } else {
            model.selectedAnnotation = nil
        }
        if model.selectedAnnotation == nil {
            menu.dismissMenu()
        } else if model.selectedAnnotation == before {
            // The scroll view hears of no change: the menu is brought back from here.
            presentMenuIfIdle()
        }
        return true
    }

    // MARK: The drag

    /// The selected annotation, and where on its page `point` (the content view's coordinates) is, when
    /// a finger going down there drags it: Select is picked, the annotation may be moved, and the point
    /// is on its page, on its box or within the slop of it.
    private func movable(at point: CGPoint) -> (info: AnnotationInfo, start: CGPoint)? {
        guard model.tool == .select, let host, let info = model.selectedAnnotationInfo, model.canChange(info),
              let location = host.pageLocation(of: point), location.page == Int(info.page) else { return nil }
        let slop = hitSlop(onPage: location.page)
        guard info.box.insetBy(dx: -slop, dy: -slop).contains(location.point) else { return nil }
        return (info, location.point)
    }

    /// Whether one finger going down at `point` (the content view's coordinates) drags the selected
    /// annotation (`movable`). Anywhere else the finger scrolls.
    func takesTouch(atContentPoint point: CGPoint) -> Bool {
        movable(at: point) != nil
    }

    /// The finger went down at `point`: the selected annotation is dragged from there, when it may be
    /// (`takesTouch`). Says whether it is. The menu goes meanwhile.
    @discardableResult
    func beginMove(atContentPoint point: CGPoint) -> Bool {
        guard let found = movable(at: point), model.pages.indices.contains(Int(found.info.page)) else { return false }
        let info = found.info
        let page = model.pages[Int(info.page)]
        moving = Move(ref: AnnotationRef(page: Int(info.page), index: info.index), start: found.start, box: info.box,
                      pageSize: CGSize(width: page.widthPt, height: page.heightPt), revision: model.revision)
        menu.dismissMenu()
        return true
    }

    /// The finger is at `point`: the outline is drawn as far from the annotation's box as the finger
    /// has gone, kept to the page (`offset(of:by:within:)`).
    func move(toContentPoint point: CGPoint) {
        guard var drag = moving, let host, let at = host.pagePoint(ofContentPoint: point, onPage: drag.ref.page) else { return }
        drag.offset = Self.offset(of: drag.box, by: CGSize(width: at.x - drag.start.x, height: at.y - drag.start.y), within: drag.pageSize)
        moving = drag
        host.pageView(for: drag.ref.page)?.overlay.dragOffset = drag.offset
    }

    /// The finger came up at `point`: the annotation is moved as far as its outline was dragged, if
    /// Select is still picked and it is still the one selected, and the drag went a point or more. The
    /// outline stays where it was dropped until the move is made, and goes with the selection, as with
    /// every change (the scroll view puts the offset back to zero as it lets go of the outline); when
    /// the move is refused, it goes back at once. The task says whether it moved; nil when nothing was
    /// handed over.
    @discardableResult
    func endMove(atContentPoint point: CGPoint) -> Task<Bool, Never>? {
        move(toContentPoint: point)
        guard let drag = moving else { return nil }
        moving = nil
        guard model.tool == .select, model.selectedAnnotation == drag.ref, hypot(drag.offset.width, drag.offset.height) >= 1 else {
            clearOffset(onPage: drag.ref.page)
            presentMenuIfIdle()
            return nil
        }
        let made = model.enqueueMoveSelectedAnnotation(by: drag.offset, workedOutAt: drag.revision)
        return Task { [weak self] in
            let ok = await made.value
            if !ok { self?.clearOffset(onPage: drag.ref.page) }
            return ok
        }
    }

    /// The drag was cancelled (another tool, a new layout, the system taking the touch): nothing moves,
    /// and the outline goes back to the annotation.
    func cancelMove() {
        guard let drag = moving else { return }
        moving = nil
        clearOffset(onPage: drag.ref.page)
    }

    private func clearOffset(onPage page: Int) {
        host?.pageView(for: page)?.overlay.dragOffset = .zero
    }

    /// How far a box `box` dragged `wanted` points goes on a page `size` big: as far, but not off the
    /// page's edges (a box already over an edge may stay where it is, but goes no further out).
    nonisolated static func offset(of box: CGRect, by wanted: CGSize, within size: CGSize) -> CGSize {
        func kept(_ value: CGFloat, low: CGFloat, high: CGFloat) -> CGFloat {
            guard value.isFinite else { return 0 }
            return min(max(value, min(0, low)), max(0, high))
        }
        return CGSize(width: kept(wanted.width, low: -box.minX, high: size.width - box.maxX),
                      height: kept(wanted.height, low: -box.minY, high: size.height - box.maxY))
    }

    // MARK: The menu

    /// What the menu offers for `info`: Edit for a note, and for a text box on a page shown upright
    /// (on a turned one its text would be typed sideways), while the document allows markup; Delete
    /// when it may be deleted (`DocumentModel.canChange`).
    func actions(for info: AnnotationInfo) -> [AnnotationAction] {
        var actions: [AnnotationAction] = []
        if model.canChangeText(of: info) {
            switch info.kind {
            case .note: actions.append(.edit)
            case .textBox where model.canAddTextBox(onPage: Int(info.page)): actions.append(.edit)
            default: break
            }
        }
        if model.canChange(info) { actions.append(.delete) }
        return actions
    }

    /// Does what the menu's `action` says to `info`: Edit opens the note sheet for a note, or puts the
    /// box to type in over a text box, with its text (the selection goes: the box takes its place);
    /// Delete deletes it.
    func perform(_ action: AnnotationAction, on info: AnnotationInfo) {
        menu.dismissMenu()
        switch action {
        case .edit:
            model.selectedAnnotation = nil
            if info.kind == .note {
                model.editNote(info)
            } else {
                textBoxes.beginEditing(info)
            }
        case .delete:
            model.enqueueDelete(AnnotationRef(page: Int(info.page), index: info.index))
        }
    }

    /// The selected annotation changed (the scroll view says, once it outlines the new one): the menu
    /// comes up over it, or goes with it.
    func selectionDidChange() {
        if model.selectedAnnotation == nil {
            cancelMove()
            menu.dismissMenu()
        } else {
            presentMenuIfIdle()
        }
    }

    /// The reader is about to scroll or zoom: the menu would be left behind, so it goes. A tap on the
    /// annotation brings it back.
    func viewportWillChange() {
        menu.dismissMenu()
    }

    /// The tool changed: a drag goes, and so does the menu, with any tool but Select.
    func toolDidChange() {
        guard model.tool != .select else { return }
        cancelMove()
        menu.dismissMenu()
    }

    /// The pages are about to be laid out again: a drag goes, since the finger's way means another
    /// distance on the page, and the menu, which points at where the annotation was.
    func layoutWillChange() {
        cancelMove()
        menu.dismissMenu()
    }

    /// Whether nothing is going on that the menu would be in the way of: no drag, and no scrolling or
    /// zooming.
    private var isIdle: Bool {
        guard let scrollView = host?.scrollView else { return false }
        return moving == nil && !scrollView.isDragging && !scrollView.isZooming && !scrollView.isDecelerating
    }

    /// Shows the menu over the selected annotation, when it offers something and some of it is on
    /// screen, and nothing is going on.
    private func presentMenuIfIdle() {
        guard isIdle, let info = model.selectedAnnotationInfo, !actions(for: info).isEmpty, let target = menuTarget() else { return }
        menu.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: CGPoint(x: target.midX, y: target.minY)))
    }

    /// The part of the selected annotation that is on screen, in the scroll view's coordinates: what the
    /// menu points at. Nil when none of it is.
    private func menuTarget() -> CGRect? {
        guard let host, let place = model.selectedAnnotationPlace,
              let box = host.scrollViewRect(of: place.rect, onPage: place.page) else { return nil }
        let visible = host.scrollView.bounds.inset(by: host.scrollView.adjustedContentInset)
        let shown = box.intersection(visible)
        return shown.isNull || shown.isEmpty ? nil : shown
    }
}

// MARK: - UIEditMenuInteractionDelegate

// As for the text selection's menu (`SelectionInteraction`): UIKit only calls these on the main thread.
extension AnnotationSelectInteraction: @preconcurrency UIEditMenuInteractionDelegate {
    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration,
                             suggestedActions: [UIMenuElement]) -> UIMenu? {
        guard let info = model.selectedAnnotationInfo else { return nil }
        let items = actions(for: info).map { action -> UIAction in
            switch action {
            case .edit:
                UIAction(title: Strings.edit, image: UIImage(systemName: "pencil")) { [weak self] _ in self?.perform(.edit, on: info) }
            case .delete:
                UIAction(title: Strings.delete, image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                    self?.perform(.delete, on: info)
                }
            }
        }
        return items.isEmpty ? nil : UIMenu(children: items)
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, targetRectFor configuration: UIEditMenuConfiguration) -> CGRect {
        menuTarget() ?? .zero
    }
}
