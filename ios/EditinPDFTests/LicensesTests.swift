import XCTest
@testable import EditinPDF

/// The Licenses screen's text: docs/THIRD-PARTY-NOTICES.md, bundled into the app (ios/project.yml), made by
/// `make notices`. The tests read the file the app really carries, so a stale or missing copy fails here.
final class LicensesTests: XCTestCase {
    /// The bundled file, read straight from the app bundle (not through the code under test).
    private var bundledText: String {
        get throws {
            let url = try XCTUnwrap(Bundle(for: PDFFileDocument.self).url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
                                    "THIRD-PARTY-NOTICES.md is not in the app bundle")
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    func testTheNoticesAreInTheAppAndNotEmpty() throws {
        let text = try bundledText
        XCTAssertGreaterThan(text.count, 10_000, "the notices are far too short to be the real list")
        XCTAssertEqual(Notices.bundledText(), text)
    }

    func testTheNoticesNameTheEngineAndTheAppItself() throws {
        let text = try bundledText
        XCTAssertTrue(text.contains("PdfCraft"))
        XCTAssertTrue(text.contains("ArtCraft Team"))
        XCTAssertTrue(text.contains("EditinPDF contributors"))
        XCTAssertTrue(text.contains("num_threads"), "the vendored num_threads is not named")
    }

    /// Every license the file says the app uses has its text in the file, under a heading of its own, and the
    /// families the engine is known to need are among them.
    func testEveryLicenseFamilyHasItsText() throws {
        let text = try bundledText
        let lines = text.components(separatedBy: "\n")
        let start = try XCTUnwrap(lines.firstIndex(of: "## Licenses in this app"), "no list of license families")
        var families: [String] = []
        for line in lines[(start + 1)...] {
            if line.hasPrefix("## ") { break }
            guard line.hasPrefix("- ") else { continue }
            families.append(String(line.dropFirst(2).prefix { $0 != ":" }))
        }
        for known in ["MIT", "Apache-2.0", "BSD-3-Clause", "ISC", "OFL-1.1", "Unicode-3.0", "MPL-2.0"] {
            XCTAssertTrue(families.contains(known), "\(known) is missing from the license families")
        }
        for family in families {
            XCTAssertTrue(text.contains("\n### \(family): "), "no text for \(family)")
        }
        XCTAssertTrue(text.contains("Permission is hereby granted, free of charge"), "the MIT text is missing")
        XCTAssertTrue(text.contains("Apache License"), "the Apache text is missing")
        XCTAssertTrue(text.contains("Mozilla Public License"), "the MPL text is missing")
        XCTAssertTrue(text.contains("SIL OPEN FONT LICENSE"), "the font license text is missing")
    }

    func testTheEngineBuildsInFontsAreCredited() throws {
        let text = try bundledText
        for credit in ["Inter", "Dancing Script", "Foxit", "Adobe", "CGATS001Compat"] {
            XCTAssertTrue(text.contains(credit), "\(credit) is not credited")
        }
    }

    func testBlocksKeepHeadingsParagraphsBulletsAndLicenseText() {
        let markdown = """
            # Title

            First line
            of a paragraph.

            ## Section
            - one
              - nested **bold**

            ```
            Permission is hereby granted.

              Indented line.
            ```
            #### Last
            """
        XCTAssertEqual(Notices.blocks(of: markdown), [
            .heading(level: 1, text: "Title"),
            .paragraph("First line of a paragraph."),
            .heading(level: 2, text: "Section"),
            .bullet(text: "one", indent: 0),
            .bullet(text: "nested **bold**", indent: 1),
            .preformatted("Permission is hereby granted.\n\n  Indented line."),
            .heading(level: 4, text: "Last"),
        ])
    }

    func testTheBundledNoticesBecomeBlocksWithHeadings() throws {
        let blocks = Notices.blocks(of: try bundledText)
        XCTAssertEqual(blocks.first, .heading(level: 1, text: "Third-party notices"))
        let headings = blocks.filter { if case .heading = $0 { return true } else { return false } }
        XCTAssertGreaterThan(headings.count, 10)
        XCTAssertTrue(blocks.contains(.heading(level: 2, text: "PdfCraft, the PDF engine")))
    }

    func testTheScreensWordsAreOurOwn() {
        XCTAssertEqual(Strings.licenses, "Licenses")
        XCTAssertFalse(Strings.licensesUnavailable.isEmpty)
    }
}
