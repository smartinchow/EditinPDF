import Foundation

/// One piece of the notices file (docs/THIRD-PARTY-NOTICES.md) as the Licenses screen shows it.
enum NoticesBlock: Equatable, Sendable {
    /// A heading; `level` 1 is the page's title, 4 the smallest.
    case heading(level: Int, text: String)
    /// A paragraph, its lines joined; it may carry inline Markdown (`code`, **bold**).
    case paragraph(String)
    /// A list item; `indent` is how deep it sits (0, 1, ...).
    case bullet(text: String, indent: Int)
    /// Text that keeps its line breaks and spaces: a license text or the engine's NOTICE file.
    case preformatted(String)
}

/// The notices file, bundled into the app, and a reader for the small part of Markdown that
/// `scripts/generate-notices.py` writes: `#` headings, paragraphs, `-` lists and fenced blocks.
enum Notices {
    static let resourceName = "THIRD-PARTY-NOTICES"
    static let resourceExtension = "md"

    /// The notices file's text, or nil when the app does not carry it.
    static func bundledText(in bundle: Bundle = .main) -> String? {
        guard let url = bundle.url(forResource: resourceName, withExtension: resourceExtension),
              let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { return nil }
        return text
    }

    /// `markdown` as blocks, in order.
    static func blocks(of markdown: String) -> [NoticesBlock] {
        var blocks: [NoticesBlock] = []
        var paragraph: [String] = []
        var fence: [String]?

        func endParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: " "))) }
            paragraph = []
        }

        for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            if fence != nil {
                if line.hasPrefix("```") {
                    blocks.append(.preformatted((fence ?? []).joined(separator: "\n")))
                    fence = nil
                } else {
                    fence?.append(line)
                }
                continue
            }
            if line.hasPrefix("```") {
                endParagraph()
                fence = []
            } else if let heading = Self.heading(in: line) {
                endParagraph()
                blocks.append(heading)
            } else if let bullet = Self.bullet(in: line) {
                endParagraph()
                blocks.append(bullet)
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
                endParagraph()
            } else {
                paragraph.append(line.trimmingCharacters(in: .whitespaces))
            }
        }
        // A fence the file never closed still shows what it held.
        if let fence { blocks.append(.preformatted(fence.joined(separator: "\n"))) }
        endParagraph()
        return blocks
    }

    private static func heading(in line: String) -> NoticesBlock? {
        let marks = line.prefix { $0 == "#" }.count
        guard (1...6).contains(marks), line.dropFirst(marks).first == " " else { return nil }
        return .heading(level: marks, text: line.dropFirst(marks + 1).trimmingCharacters(in: .whitespaces))
    }

    private static func bullet(in line: String) -> NoticesBlock? {
        let spaces = line.prefix { $0 == " " }.count
        let rest = line.dropFirst(spaces)
        guard rest.hasPrefix("- ") else { return nil }
        return .bullet(text: rest.dropFirst(2).trimmingCharacters(in: .whitespaces), indent: spaces / 2)
    }
}
