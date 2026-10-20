import EditinPDFCore
import SwiftUI
import XCTest
@testable import EditinPDF

@MainActor
final class ToolModeTests: XCTestCase {
    func testPaletteFollowsWidth() {
        XCTAssertEqual(PaletteLayout.for(.compact), .bottomBar)
        XCTAssertEqual(PaletteLayout.for(.regular), .sidePalette)
        XCTAssertEqual(PaletteLayout.for(nil), .bottomBar)
    }

    func testStylesPersistPerTool() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: #function)); d.removePersistentDomain(forName: #function)
        let s = ToolStyleStore(defaults: d); var ink = s[.ink]; ink.width = 6; s[.ink] = ink
        XCTAssertEqual(ToolStyleStore(defaults: d)[.ink].width, 6)
        XCTAssertNotEqual(ToolStyleStore(defaults: d)[.rectangle].width, 6)
    }

    func testDefaultStyles() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: #function)); d.removePersistentDomain(forName: #function)
        let s = ToolStyleStore(defaults: d)
        XCTAssertEqual(s[.highlight].color, RGBA(r: 1, g: 0.9, b: 0))
        XCTAssertEqual(s[.underline].color, RGBA(r: 0, g: 0.4, b: 1))
        XCTAssertEqual(s[.strikeout].color, RGBA(r: 0.9, g: 0.1, b: 0.1))
        XCTAssertEqual(s[.ink].color, RGBA(r: 0, g: 0, b: 0)); XCTAssertEqual(s[.ink].width, 2)
        for shape in [Tool.rectangle, .oval, .line, .arrow] {
            XCTAssertEqual(s[shape].color, RGBA(r: 0.9, g: 0.1, b: 0.1), "\(shape)"); XCTAssertEqual(s[shape].width, 2)
            XCTAssertFalse(s[shape].fill)
        }
        XCTAssertEqual(s[.textBox].color, RGBA(r: 0, g: 0, b: 0)); XCTAssertEqual(s[.textBox].fontSize, 14)
    }

    func testUnreadableStoredStylesFallBackToTheDefaults() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: #function)); d.removePersistentDomain(forName: #function)
        d.set(Data("not json".utf8), forKey: "toolStyles")
        XCTAssertEqual(ToolStyleStore(defaults: d)[.ink].width, 2)
    }

    func testRGBAConvertsToTheEnginesColor() {
        XCTAssertEqual(RGBA(r: 0.25, g: 0.5, b: 1).rgbColor, RgbColor(red: 0.25, green: 0.5, blue: 1))
    }

    func testEveryToolHasATitleAndAnIcon() {
        XCTAssertEqual(Tool.allCases.count, 13)
        for tool in Tool.allCases {
            XCTAssertFalse(tool.title.isEmpty, "\(tool)")
            XCTAssertNotNil(UIImage(systemName: tool.systemImage), "\(tool): no symbol \(tool.systemImage)")
        }
        XCTAssertEqual(Tool.ink.systemImage, "scribble"); XCTAssertEqual(Tool.select.systemImage, "cursorarrow")
        XCTAssertEqual(Tool.signature.systemImage, "signature"); XCTAssertEqual(Tool.signature.title, "Sign")
    }

    /// Sign places a saved signature with a tap, always black and 1.5 points wide: it has no style to
    /// pick, and it is refused where markup is, turned pages included in neither.
    func testSignPlacesByTapAndHasNoStyle() {
        XCTAssertTrue(Tool.signature.placesByTap)
        XCTAssertTrue(Tool.signature.annotates)
        XCTAssertFalse(Tool.signature.hasStyle); XCTAssertFalse(Tool.signature.usesWidth); XCTAssertFalse(Tool.signature.drawsShape)
        XCTAssertNil(Tool.signature.markupKind)
        XCTAssertEqual(Tool.signature.refusal(canAnnotate: false, pageRotation: 0), Strings.markupNotAllowed)
        XCTAssertNil(Tool.signature.refusal(canAnnotate: true, pageRotation: 90), "a signature is ink: it goes on a turned page too")
        XCTAssertEqual(SignatureStore.lineWidth, 1.5)
        XCTAssertEqual(SignatureStore.color, RGBA(r: 0, g: 0, b: 0))
    }

    func testWhatEachToolsStyleOffers() {
        XCTAssertTrue(Tool.textBox.usesFontSize); XCTAssertFalse(Tool.ink.usesFontSize)
        XCTAssertTrue(Tool.rectangle.usesFill); XCTAssertTrue(Tool.oval.usesFill); XCTAssertFalse(Tool.line.usesFill)
        XCTAssertTrue(Tool.ink.usesWidth); XCTAssertTrue(Tool.arrow.usesWidth); XCTAssertFalse(Tool.highlight.usesWidth)
        XCTAssertFalse(Tool.select.hasStyle); XCTAssertFalse(Tool.eraser.hasStyle); XCTAssertTrue(Tool.note.hasStyle)
    }

    func testToolsAreRefusedWhenTheDocumentCannotBeAnnotated() {
        XCTAssertNil(Tool.select.refusal(canAnnotate: false, pageRotation: 0))
        XCTAssertEqual(Tool.ink.refusal(canAnnotate: false, pageRotation: 0), Strings.markupNotAllowed)
        XCTAssertEqual(Tool.eraser.refusal(canAnnotate: false, pageRotation: 0), Strings.markupNotAllowed)
        XCTAssertNil(Tool.ink.refusal(canAnnotate: true, pageRotation: 90))
    }

    func testTextBoxesAreRefusedOnTurnedPages() {
        XCTAssertEqual(Tool.textBox.refusal(canAnnotate: true, pageRotation: 90), Strings.textBoxNeedsUprightPage)
        XCTAssertNil(Tool.textBox.refusal(canAnnotate: true, pageRotation: 0))
        XCTAssertEqual(Tool.textBox.refusal(canAnnotate: false, pageRotation: 90), Strings.markupNotAllowed)
    }

    func testTheModelStartsReadingAndLeavesAToolTheDocumentRefuses() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        XCTAssertNil(m.tool)
        m.tool = .ink
        XCTAssertEqual(m.tool, .ink)
        XCTAssertTrue(m.canUse(.ink))
        XCTAssertNil(m.refusal(of: .ink))
    }

    func testTheModelSaysWhyATextBoxIsRefusedOnATurnedPage() async throws {
        let (m, _) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        m.currentPage = 0
        XCTAssertEqual(m.refusal(of: .textBox), Strings.textBoxNeedsUprightPage)
        XCTAssertFalse(m.canUse(.textBox))
        m.currentPage = 1
        XCTAssertTrue(m.canUse(.textBox))
    }
}
