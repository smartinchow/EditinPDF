import CoreGraphics
import EditinPDFCore

/// The arithmetic of the Organize screen, kept apart from its views so it can be tested: where a
/// drop moves pages to, what is selected afterwards, where a blank page goes and how big it is, and
/// which page the reader is on after pages are deleted, moved or inserted. Pages count from 0.
enum OrganizeMath {
    /// The size of a blank page when there is no page beside it to copy: US Letter.
    static let letter = CGSize(width: 612, height: 792)

    /// The bridge's `MovePages.to` for dropping `moving` (0-based, any order) before the item at
    /// `dropIndex` of the grid as it was (the page count for after the last one): the pages before
    /// the drop that are moving are not there any more to count.
    static func moveTarget(moving: [Int], dropIndex: Int) -> Int {
        dropIndex - Set(moving).filter { $0 < dropIndex }.count
    }

    /// Where the moved pages are once moved to `target`: next to each other, from there on.
    static func selectionAfterMove(moving: [Int], to target: Int) -> Set<Int> {
        Set(target..<target + Set(moving).count)
    }

    /// Where Insert Blank Page puts its page: after the last selected page, else at the end.
    static func insertionIndex(selection: Set<Int>, pageCount: Int) -> Int {
        guard let last = selection.filter({ (0..<pageCount).contains($0) }).max() else { return pageCount }
        return last + 1
    }

    /// The size of a blank page inserted at `index`: that of the page before it as shown (turned the
    /// way it is), else the page after it, else (or when that page's size is unusable) Letter.
    static func blankSize(near index: Int, pages: [PageInfo]) -> CGSize {
        let neighbour = pages.indices.contains(index - 1) ? pages[index - 1]
            : pages.indices.contains(index) ? pages[index] : nil
        guard let neighbour, neighbour.widthPt.isFinite, neighbour.heightPt.isFinite,
              neighbour.widthPt > 0, neighbour.heightPt > 0 else { return letter }
        return CGSize(width: neighbour.widthPt, height: neighbour.heightPt)
    }

    /// The page that was `page` before `edits` were made, after them: so the reader stays on the same
    /// page when pages before it are deleted, moved or inserted. A deleted page leaves the reader on
    /// the page that followed it. `pagesAdded` is how many pages the edits added (negative when they
    /// removed some), for an insert from a file whose number of pages the edit does not say. The
    /// result may be past the last page; the model keeps it on one.
    static func readerPage(_ page: Int, after edits: [Edit], pagesAdded: Int) -> Int {
        var page = page
        for edit in edits {
            switch edit {
            case .deletePages(let pages):
                page -= Set(pages).filter { Int($0) < page }.count
            case .movePages(let pages, let to):
                let moving = Set(pages.map(Int.init)).sorted()
                if let place = moving.firstIndex(of: page) {
                    page = Int(to) + place
                } else {
                    // Out of the pages that stay, in order, the moved ones go in at `to`.
                    let rest = page - moving.filter { $0 < page }.count
                    page = rest >= Int(to) ? rest + moving.count : rest
                }
            case .insertBlankPage(let at, _, _):
                if Int(at) <= page { page += 1 }
            case .insertPagesFrom(_, _, let pages, let at):
                if Int(at) <= page { page += pages?.count ?? max(pagesAdded, 0) }
            case .rotatePages, .setInfo, .addTextMarkup, .addNote, .setAnnotationContents, .addInk, .addSignature,
                 .addTextBox, .addShape, .addLine, .setFieldValue, .deleteAnnotation, .deleteAnnotations, .moveAnnotation:
                break
            }
        }
        return max(page, 0)
    }
}
