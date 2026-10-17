import CoreGraphics
import EditinPDFCore
import Foundation
import os

/// The engine's side of text selection: every call that finds a word or reads a page's text is made
/// here, off the main actor, one at a time.
///
/// Reading a page's text takes a moment the first time (the engine keeps what it has read, but hands
/// over a copy of it for each call), and a dragged handle asks many times a second, so none of it
/// may happen where the screen is drawn. The worker keeps the glyph lines of the last few pages it has
/// been asked about, so that dragging a handle reads a page once, and drops them all when the document
/// changes.
///
/// It does as it is asked, and one thing more: a request whose task has been cancelled by the time its
/// turn comes is not made. The controller cancels a request when a newer one supersedes it, so of the
/// points a drag sends while the engine is busy, the ones in between never reach the engine.
actor SelectionWorker {
    /// How many pages' glyph lines are kept: the page being selected on, and a few spare for a
    /// selection that moves between pages.
    static let pagesKept = 4

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "selection")

    private let document: any PdfDocumentProtocol
    private var lines: [Int: GlyphLines] = [:]
    /// The pages in `lines`, the one used longest ago first.
    private var used: [Int] = []
    /// The document's revision `lines` were read at.
    private var revision: UInt64

    init(document: any PdfDocumentProtocol) {
        self.document = document
        revision = document.revision()
    }

    /// The word at `point` (PDF points) of `page`, counting from 0. Nil when there is none there, the
    /// page has no text or does not exist, or the request was cancelled.
    func word(page: Int, at point: CGPoint) -> EditinPDFCore.TextSelection? {
        guard !Task.isCancelled, let index = UInt32(exactly: page), point.x.isFinite, point.y.isFinite else { return nil }
        do {
            return try document.selectWord(page: index, x: point.x, y: point.y)
        } catch {
            Self.log.error("no word on page \(page): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// The glyphs of `page` from `anchor`, which stay selected, to the gap nearest `point`: see
    /// `GlyphLines.range(anchor:gap:count:)`. Nil when the page has no glyph to land on, or the request
    /// was cancelled.
    func range(page: Int, anchor: Int, to point: CGPoint) -> EditinPDFCore.TextSelection? {
        guard !Task.isCancelled, let index = UInt32(exactly: page), point.x.isFinite, point.y.isFinite,
              let glyphs = glyphLines(of: page), let gap = glyphs.nearestGap(to: point),
              let range = GlyphLines.range(anchor: anchor, gap: gap, count: glyphs.count) else { return nil }
        // Reading a page's text can take long enough for the request to have been superseded meanwhile.
        guard !Task.isCancelled else { return nil }
        do {
            return try document.selectRange(page: index, start: UInt32(clamping: range.lowerBound), end: UInt32(clamping: range.upperBound))
        } catch {
            Self.log.error("no range on page \(page): \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    /// Reads `page`'s glyphs now, so that the first `range(page:anchor:to:)` for it does not wait for them.
    func prepare(page: Int) {
        guard !Task.isCancelled else { return }
        _ = glyphLines(of: page)
    }

    // MARK: Glyph lines

    private func glyphLines(of page: Int) -> GlyphLines? {
        let current = document.revision()
        if current != revision {
            // Indices change with the document: what was read is of a document that is gone.
            lines.removeAll()
            used.removeAll()
            revision = current
        }
        if let kept = lines[page] {
            use(page)
            return kept
        }
        guard let index = UInt32(exactly: page) else { return nil }
        do {
            let made = GlyphLines(glyphs: try document.pageText(page: index).glyphs)
            lines[page] = made
            use(page)
            while used.count > Self.pagesKept {
                lines[used.removeFirst()] = nil
            }
            return made
        } catch {
            Self.log.error("the text of page \(page) could not be read: \(String(describing: error), privacy: .private)")
            return nil
        }
    }

    private func use(_ page: Int) {
        used.removeAll { $0 == page }
        used.append(page)
    }
}
