import EditinPDFCore
import Foundation
import XCTest
@testable import EditinPDF

/// Helpers shared by the editing tests.

/// The bytes of `<name>.pdf` from the test bundle's Fixtures.
func fixtureData(_ name: String) throws -> Data {
    let bundle = Bundle(for: FixtureBundleMarker.self)
    return try Data(contentsOf: XCTUnwrap(bundle.url(forResource: name, withExtension: "pdf"), "no fixture \(name).pdf"))
}

/// Names the test bundle for `Bundle(for:)`.
private final class FixtureBundleMarker {}

/// A model of `<fixture>.pdf`, opened, with a fresh `UndoManager` of its own wired in, as the
/// document scene's would be. The caller keeps the undo manager: the model only holds it weakly. Its
/// tools' styles are its own (`isolatedToolStyles`): a test that changes one changes no other test's,
/// nor the app's. So is its signature store (`isolatedSignatures`), empty.
@MainActor
func makeModel(fixture: String = "sample") throws -> (DocumentModel, UndoManager) {
    let model = DocumentModel(outcome: OpenOutcome(bytes: try fixtureData(fixture)), toolStyles: isolatedToolStyles(),
                              signatures: isolatedSignatures())
    guard case .open = model.state else { throw FixtureError.notOpen(fixture) }
    let undoManager = UndoManager()
    model.undoManager = undoManager
    return (model, undoManager)
}

/// Tools' styles kept in user defaults of the tests' own, emptied first: every tool's first style. The
/// app's (the test host's standard defaults) are left alone. A store reads its defaults once, when it
/// is made, so emptying them for the next one changes none made before.
@MainActor
func isolatedToolStyles() -> ToolStyleStore {
    let suite = "EditinPDFTests.toolStyles"
    guard let defaults = UserDefaults(suiteName: suite) else { return ToolStyleStore(defaults: UserDefaults()) }
    defaults.removePersistentDomain(forName: suite)
    return ToolStyleStore(defaults: defaults)
}

/// A model of `bytes` whose tools' styles and signature store are the tests' own (`isolatedToolStyles`,
/// `isolatedSignatures`), not the app's.
@MainActor
func isolatedModel(bytes: Data) -> DocumentModel {
    DocumentModel(outcome: OpenOutcome(bytes: bytes), toolStyles: isolatedToolStyles(), signatures: isolatedSignatures())
}

/// A signature store in a folder of its own under the temporary folder, with nothing saved: a test that
/// saves a signature saves it there, never in the app's Application Support.
@MainActor
func isolatedSignatures() -> SignatureStore {
    SignatureStore(directory: FileManager.default.temporaryDirectory
        .appending(path: "EditinPDFTests-signatures/\(UUID().uuidString)", directoryHint: .isDirectory))
}

/// The middle of the first glyph on page 0 of the model's document, in view space.
@MainActor
func firstGlyphCenter(_ m: DocumentModel) throws -> CGPoint {
    let document = try XCTUnwrap(m.document())
    let glyph = try XCTUnwrap(document.pageText(page: 0).glyphs.first, "page 0 has no text")
    return CGPoint(x: glyph.rect.x + glyph.rect.width / 2, y: glyph.rect.y + glyph.rect.height / 2)
}

enum FixtureError: Error { case notOpen(String) }

/// An annotation of kind `kind` at `rect` (view space) on `page`, number `index` there.
func info(page: Int = 0, index: UInt32, rect: CGRect = CGRect(x: 0, y: 0, width: 10, height: 10),
          kind: AnnotationKind = .rectangle) -> AnnotationInfo {
    AnnotationInfo(page: UInt32(page), index: index, kind: kind,
                   rect: Rect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height),
                   contents: nil, author: nil, modified: nil, color: nil, locked: false)
}

/// A 10 × 10 rectangle annotation whose top is at `y` on `page`.
func info(page: Int = 0, index: UInt32, y: CGFloat) -> AnnotationInfo {
    info(page: page, index: index, rect: CGRect(x: 0, y: y, width: 10, height: 10))
}
