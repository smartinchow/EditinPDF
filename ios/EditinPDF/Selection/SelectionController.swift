import CoreGraphics
import EditinPDFCore
import Observation
import UIKit

/// Which end of the selected text a drag moves.
enum SelectionHandle: Sendable {
    case start
    case end
}

/// The text the reader has selected on a page: a long press selects the word under the finger, dragging
/// a handle extends the selection from the word, and what is selected can be copied.
///
/// Finding words and ranges takes calls into the engine, and a dragged handle makes many of them a
/// second, so none is made on the main actor: the work goes to a `SelectionWorker`, and the answer is
/// kept here on the main actor if nothing newer has been asked since. Every request, and `clear()`,
/// counts a new generation and cancels the work before it; an answer from an older one is dropped, so
/// a slow word that has been asked over never replaces the new one, and a drag that is overtaken by the
/// next point shows only the last. Because the work is done off the main actor, the selection changes a
/// moment after a request, not during it: `waitUntilSettled()` is for the callers that need to be sure.
///
/// The selection is on one page: M1 extends within the page it began on. Points are in PDF points of
/// that page (view space: the origin at its top-left, y down), the units the engine and the page
/// overlay use; a point past the page's edge is a point on the text nearest it.
///
/// The controller belongs to one document and holds only the engine's document, never the model that
/// holds the controller. (Glyph indices are only good for one revision of the document. The worker
/// drops what it read when the revision changes, but a selection already made is not touched: when
/// editing arrives, whoever changes the document has to `clear()` it.)
@MainActor
@Observable
final class SelectionController {
    /// The selected text, with its page, the glyphs it covers and the boxes to highlight; nil when
    /// nothing is selected.
    private(set) var selection: EditinPDFCore.TextSelection?

    /// The selected text as it reads, empty when nothing is selected.
    var text: String { selection?.text ?? "" }

    /// The boxes of the selection on its page, in PDF points, for the viewer to draw. Boxes that
    /// cannot be drawn are left out. Nil when nothing is selected.
    var pageRects: (page: Int, rects: [CGRect])? {
        selection.map { (page: Int($0.page), rects: Self.rects(of: $0)) }
    }

    @ObservationIgnored private let worker: SelectionWorker
    /// Counts the requests (and clears): an answer remembers the count it was asked at.
    @ObservationIgnored private var generation = 0
    /// The work for the latest request, replaced (and the old one cancelled) by the next.
    @ObservationIgnored private var pending: Task<Void, Never>?
    /// The glyph a drag keeps selected, which it extends from; nil when there is nothing to extend.
    @ObservationIgnored private var anchor: Int?

    /// A selection in `document`, whose engine calls are made off the main actor.
    init(document: any PdfDocumentProtocol) {
        worker = SelectionWorker(document: document)
    }

    /// Selects the word at `point` of `page` (counting from 0), replacing the selection, a moment
    /// later. Nothing is selected, and nothing that is selected is lost, when there is no word there.
    func beginWord(page: Int, at point: CGPoint) {
        let generation = supersede()
        let worker = worker
        pending = Task { [weak self] in
            let found = await worker.word(page: page, at: point)
            guard let self, self.isCurrent(generation), let found else { return }
            self.selection = found
            // A drag with no handle named moves the end, from the start of the word.
            self.anchor = Int(found.start)
            // Reads the page's glyphs, so that the first drag does not wait for them.
            await worker.prepare(page: page)
        }
    }

    /// Takes hold of one end of the selection, for the drag whose points `extend(to:)` is given: the
    /// glyph at the other end stays selected, and the dragged end goes where the points go. Nothing
    /// happens when nothing is selected.
    func beginExtending(_ handle: SelectionHandle) {
        guard let selection, selection.end > selection.start else { return }
        anchor = handle == .end ? Int(selection.start) : Int(selection.end) - 1
    }

    /// Moves the end that is being dragged to the gap between glyphs nearest `point`, a moment later;
    /// the end that is not stays selected. With no handle taken hold of, it is the end that was selected
    /// by `beginWord`, which moves from the start of that word. Only on the page the selection is on:
    /// a point outside it goes to the text nearest. Nothing happens when nothing is selected or `point`
    /// is not a number.
    func extend(to point: CGPoint) {
        guard let selection, let anchor, point.x.isFinite, point.y.isFinite else { return }
        let generation = supersede()
        let page = Int(selection.page)
        let worker = worker
        pending = Task { [weak self] in
            let found = await worker.range(page: page, anchor: anchor, to: point)
            guard let self, self.isCurrent(generation), let found else { return }
            self.selection = found
        }
    }

    /// Selects nothing, at once, and drops any request that is still on its way (its answer is thrown
    /// away when it arrives).
    func clear() {
        _ = supersede()
        anchor = nil
        if selection != nil { selection = nil }
    }

    /// Puts the selected text on the pasteboard, and says whether there was any to put. The selection
    /// stays as it is.
    @discardableResult
    func copySelection() -> Bool {
        let text = text
        guard !text.isEmpty else { return false }
        UIPasteboard.general.string = text
        return true
    }

    /// Returns once everything asked so far has been answered or dropped. For tests, which cannot see
    /// that nothing more is coming.
    func waitUntilSettled() async {
        while let task = pending {
            await task.value
            if pending == task { pending = nil }
        }
    }

    // MARK: Requests

    /// Starts a new generation: the work before it is cancelled and its answer will be dropped.
    private func supersede() -> Int {
        generation += 1
        pending?.cancel()
        return generation
    }

    private func isCurrent(_ generation: Int) -> Bool {
        generation == self.generation && !Task.isCancelled
    }

    // MARK: Boxes

    /// The boxes of `selection` as `CGRect`s, in PDF points of its page, as the engine gives them: one
    /// for each line. A box that cannot be drawn, with no area or a number that is not finite, is left
    /// out.
    nonisolated static func rects(of selection: EditinPDFCore.TextSelection) -> [CGRect] {
        selection.rects.compactMap { box in
            guard box.x.isFinite, box.y.isFinite, box.width.isFinite, box.height.isFinite,
                  box.width > 0, box.height > 0 else { return nil }
            return CGRect(x: box.x, y: box.y, width: box.width, height: box.height)
        }
    }
}
