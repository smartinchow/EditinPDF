import EditinPDFCore
import Foundation
import Observation

/// What the Organize screen does, apart from how it looks: the selected pages, which of its actions
/// can be used now, and the changes they hand to the model.
///
/// A change that renumbers the pages (delete, move, insert) is worked out against the pages on screen.
/// Handed over while another such change is still being made, the model would refuse it ("The document
/// changed. Try again."), so they are off while the model is making any change, and an action that
/// comes in meanwhile (a second tap that beat the button's update) is ignored. A rotation names pages
/// that a rotation before it does not move, so rotations queue, except behind a renumbering of this
/// screen's own.
///
/// The selection after a change: a rotation keeps it, a move selects the moved pages where they landed,
/// a delete clears it and an insert selects the inserted page. Any other change (an undo or redo)
/// clears it, since the pages may have moved under it.
@MainActor
@Observable
final class OrganizeController {
    let model: DocumentModel
    /// The selected pages, counting from 0.
    var selection: Set<Int> = []
    /// The revisions this screen's own changes made, so `modelDidChange` can tell them from others.
    @ObservationIgnored private var ownRevisions: Set<UInt64> = []
    /// How many of this screen's changes are waiting or being made.
    private var ownPending = 0
    /// Whether one of them renumbers the pages.
    private var renumberingPending = false

    init(model: DocumentModel) {
        self.model = model
    }

    /// Whether the document allows its pages to be changed; false until that is known.
    var canOrganize: Bool { model.capabilities?.canOrganize == true }
    /// Whether the document's pages are known not to be changeable (not merely not known yet).
    var organizeIsRefused: Bool { model.capabilities.map { !$0.canOrganize } ?? false }

    /// Whether a change that renumbers the pages can be handed over now: nothing is being made.
    private var canRenumber: Bool { canOrganize && !model.isApplying }

    var canDelete: Bool { canRenumber && !selection.isEmpty && selection.count < model.pageCount }
    var canMove: Bool { canRenumber }
    var canInsertBlank: Bool { canRenumber }
    var canRotate: Bool { canOrganize && !selection.isEmpty && !renumberingPending }

    /// Whether every page is selected (Select All then reads Deselect All).
    var allSelected: Bool { model.pageCount > 0 && selection.count == model.pageCount }

    /// Selects every page, or none once they all are.
    func selectAll() {
        selection = allSelected ? [] : Set(0..<model.pageCount)
    }

    /// Selects `page`, or takes it out of the selection.
    func toggle(_ page: Int) {
        if selection.contains(page) { selection.remove(page) } else { selection.insert(page) }
    }

    /// Turns the selected pages a quarter turn: 90 clockwise, -90 anticlockwise.
    @discardableResult
    func rotate(by degrees: Int32) -> Task<Void, Never>? {
        guard canRotate else { return nil }
        let pages = selection.sorted()
        return run(.rotatePages(pages: pages.map(UInt32.init), degrees: degrees), named: Strings.actionRotate,
                   touching: Set(pages), renumbers: false) { _ in }
    }

    /// Deletes the selected pages, all in one change (one step of Undo).
    @discardableResult
    func deleteSelection() -> Task<Void, Never>? {
        guard canDelete else { return nil }
        let pages = selection.sorted()
        return run(.deletePages(pages: pages.map(UInt32.init)), named: Strings.actionDelete,
                   touching: nil, renumbers: true) { $0.selection = [] }
    }

    /// Adds a blank page after the selection (at the end with none), the size of the page beside it.
    @discardableResult
    func insertBlank() -> Task<Void, Never>? {
        guard canInsertBlank else { return nil }
        let index = OrganizeMath.insertionIndex(selection: selection, pageCount: model.pageCount)
        let size = OrganizeMath.blankSize(near: index, pages: model.pages)
        return run(.insertBlankPage(at: UInt32(index), widthPt: size.width, heightPt: size.height),
                   named: Strings.actionInsertBlank, touching: nil, renumbers: true) { $0.selection = [index] }
    }

    /// Moves `pages` to just before the item at `dropIndex` of the grid as it is (the page count for
    /// the end). A drop that leaves every page where it was changes nothing.
    @discardableResult
    func move(_ pages: [Int], dropIndex: Int) -> Task<Void, Never>? {
        let moving = Set(pages).filter { (0..<model.pageCount).contains($0) }.sorted()
        guard canMove, !moving.isEmpty, (0...model.pageCount).contains(dropIndex) else { return nil }
        let target = OrganizeMath.moveTarget(moving: moving, dropIndex: dropIndex)
        // Already together, in order, at the target: nothing would move.
        guard moving != Array(target..<target + moving.count) else { return nil }
        return run(.movePages(pages: moving.map(UInt32.init), to: UInt32(target)), named: Strings.actionMove,
                   touching: nil, renumbers: true) { $0.selection = OrganizeMath.selectionAfterMove(moving: moving, to: target) }
    }

    /// Told of the model's last change: one this screen did not make (an undo or redo) clears the
    /// selection, unless one of its own is still on its way (it sets the selection itself). Whatever
    /// happens, no page that is not there stays selected.
    func modelDidChange(_ change: PageChange?) {
        if let change, !ownRevisions.contains(change.revision), ownPending == 0 {
            selection = []
        }
        selection = selection.filter { $0 < model.pageCount }
    }

    /// Hands `edit` to the model, and once it is made sets the selection with `selected`.
    private func run(_ edit: Edit, named name: String, touching pages: Set<Int>?, renumbers: Bool,
                     selected: @escaping @MainActor (OrganizeController) -> Void) -> Task<Void, Never> {
        let made = model.enqueue([edit], named: name, touching: pages)
        ownPending += 1
        if renumbers { renumberingPending = true }
        return Task { [weak self] in
            let ok = await made.value
            guard let self else { return }
            if ok {
                ownRevisions.insert(model.revision)
                selected(self)
            }
            ownPending -= 1
            if renumbers { renumberingPending = false }
            selection = selection.filter { $0 < model.pageCount }
        }
    }
}
