import CoreGraphics
import EditinPDFCore
import Foundation

/// The glyph boxes of a document's pages (view space), for deciding at once, on the main actor, whether
/// a finger went down on text (`MarkupInteraction.isNearText`). Reading a page's text is engine work, so
/// it is done off the main actor; this keeps what has been read and decides what to read next.
///
/// Reading is throttled, since every read takes one of the engine's renderer slots, which the tiles of
/// the page being landed on need too, and a thread of the cooperative pool:
/// - Only the pages **wanted** are read: the pages in view, at most `pagesKept` of them, nearest the
///   middle of the view first (`want(_:)`, which the scroll view calls as it scrolls, replacing the
///   pages wanted before), and a page a finger has just gone down on, first of all (`request(_:)`).
/// - **One read at a time.** Which page to read is decided when the read starts, from the pages wanted
///   then: a page scrolled past before its turn came is never read. And the next read is decided on the
///   main actor's next turn, not at once, so many requests made in one go come to one decision.
/// - A read that comes back for a page no longer wanted is kept as the page used **longest ago**, the
///   first to be dropped, so it never pushes out a page in view; the boxes of at most `pagesKept` pages
///   are kept.
/// - Everything read is of one revision of the document: boxes of an older one are dropped, and a read
///   that comes back after the document changed is not kept.
/// - A page whose text cannot be read is read **once** for a revision: it counts as a page without text
///   (a finger there scrolls) until the document changes, and is not asked for again meanwhile, so it
///   never holds the reading up, nor takes the engine's time over and over.
@MainActor
final class PageTextBoxes {
    /// Reads the glyph boxes of a page (counting from 0) at a revision of the document, off the main
    /// actor; nil when the page cannot be read, or the document is at another revision.
    typealias Reader = @Sendable (_ page: Int, _ revision: UInt64) -> [CGRect]?

    /// How many pages' boxes are kept, and how many pages are wanted at most.
    static let pagesKept = 8

    private let read: Reader
    private let currentRevision: @MainActor () -> UInt64
    private var boxes: [Int: [CGRect]] = [:]
    /// The pages in `boxes`, the one used longest ago first.
    private var used: [Int] = []
    /// The pages whose text could not be read at `revision`: not read again until it changes.
    private var unreadable: Set<Int> = []
    /// The revision `boxes` and `unreadable` are of; nil when there are none.
    private var revision: UInt64?
    /// The pages to read, most wanted first.
    private(set) var wanted: [Int] = []
    /// The read on its way, if any.
    private var reading: Task<Void, Never>?
    /// The decision of what to read next, made on the main actor's next turn, if one is due.
    private var next: Task<Void, Never>?

    /// Boxes read by `read`, of the revision `revision` says the document is at.
    init(revision: @escaping @MainActor () -> UInt64, read: @escaping Reader) {
        currentRevision = revision
        self.read = read
    }

    /// The boxes of `page`'s glyphs, when they have been read at the document's revision; nil when not
    /// (yet).
    func boxes(onPage page: Int) -> [CGRect]? {
        dropIfStale()
        if unreadable.contains(page) { return [] }
        guard let found = boxes[page] else { return nil }
        use(page)
        return found
    }

    /// Asks for `page` before every other: a finger has gone down on it.
    func request(_ page: Int) {
        wanted.removeAll { $0 == page }
        wanted.insert(page, at: 0)
        if wanted.count > Self.pagesKept { wanted.removeLast(wanted.count - Self.pagesKept) }
        scheduleNext()
    }

    /// The pages to read ahead of a touch, most wanted first (at most `pagesKept` of them are taken),
    /// in place of those wanted before. None stops every read that has not started.
    func want(_ pages: [Int]) {
        var seen = Set<Int>()
        wanted = Array(pages.filter { seen.insert($0).inserted }.prefix(Self.pagesKept))
        scheduleNext()
    }

    /// Returns once nothing is being read and nothing more is due to be. For tests.
    func settle() async {
        while true {
            if let next {
                await next.value
            } else if let reading {
                await reading.value
            } else {
                return
            }
        }
    }

    // MARK: Reading

    private func scheduleNext() {
        guard next == nil else { return }
        next = Task { [weak self] in
            guard let self else { return }
            self.next = nil
            self.startNext()
        }
    }

    /// Starts reading the most wanted page that has not been read, unless a read is on its way.
    private func startNext() {
        guard reading == nil else { return }
        dropIfStale()
        guard let page = wanted.first(where: { boxes[$0] == nil && !unreadable.contains($0) }) else { return }
        let revision = currentRevision()
        let read = read
        reading = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) { read(page, revision) }.value
            guard let self else { return }
            self.reading = nil
            self.keep(found, ofPage: page, at: revision)
            self.startNext()
        }
    }

    private func keep(_ found: [CGRect]?, ofPage page: Int, at revision: UInt64) {
        // The document may have changed while the page was read.
        guard currentRevision() == revision else { return }
        dropIfStale()
        self.revision = revision
        guard let found else {
            // Not read again at this revision (the reader also says nil when the engine's document had
            // moved on from it, which the model's revision follows in a moment: then this is dropped).
            unreadable.insert(page)
            return
        }
        boxes[page] = found
        used.removeAll { $0 == page }
        if wanted.contains(page) {
            used.append(page)
        } else {
            // Late, for a page scrolled past: the first to go, never one in view.
            used.insert(page, at: 0)
        }
        trim()
    }

    private func dropIfStale() {
        guard let revision, revision != currentRevision() else { return }
        boxes.removeAll()
        used.removeAll()
        unreadable.removeAll()
        self.revision = nil
    }

    private func use(_ page: Int) {
        used.removeAll { $0 == page }
        used.append(page)
        trim()
    }

    private func trim() {
        while used.count > Self.pagesKept {
            boxes[used.removeFirst()] = nil
        }
    }

    // MARK: The engine

    /// The boxes of `page`'s glyphs in `document`, as the engine has them at `revision`; nil when the
    /// page cannot be read, or the document is at another revision before or after. Blocks: off the
    /// main actor only.
    nonisolated static func glyphBoxes(of document: PdfDocument, page: Int, at revision: UInt64) -> [CGRect]? {
        guard let index = UInt32(exactly: page), document.revision() == revision,
              let text = try? document.pageText(page: index), document.revision() == revision else { return nil }
        return text.glyphs.compactMap { glyph in
            let r = glyph.rect
            guard r.x.isFinite, r.y.isFinite, r.width.isFinite, r.height.isFinite, r.width >= 0, r.height >= 0 else { return nil }
            return CGRect(x: r.x, y: r.y, width: r.width, height: r.height)
        }
    }
}
