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
/// saves a signature saves it there, never in the app's Application Support. The folder is removed when
/// the test that made it finishes (`TemporaryFolders`). `isProtectedDataAvailable` as the store's.
@MainActor
func isolatedSignatures(isProtectedDataAvailable: @escaping @MainActor () -> Bool = { true }) -> SignatureStore {
    let folder = FileManager.default.temporaryDirectory
        .appending(path: "EditinPDFTests-signatures/\(UUID().uuidString)", directoryHint: .isDirectory)
    TemporaryFolders.observer.add(folder)
    return SignatureStore(directory: folder, isProtectedDataAvailable: isProtectedDataAvailable)
}

/// Removes, as each test finishes, the folders made for it (`add`): it watches the tests run, so a
/// helper with no test case of its own to tear down with can still clean up after one.
final class TemporaryFolders: NSObject, XCTestObservation, @unchecked Sendable {
    /// The one watching, put to watch the first time it is asked for.
    @MainActor static var observer: TemporaryFolders {
        if let watching { return watching }
        let made = TemporaryFolders()
        XCTestObservationCenter.shared.addTestObserver(made)
        watching = made
        return made
    }
    @MainActor private static var watching: TemporaryFolders?

    private let lock = NSLock()
    private var folders: [URL] = []

    /// `folder` is removed when the test running now finishes.
    func add(_ folder: URL) {
        lock.withLock { folders.append(folder) }
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        let made = lock.withLock { () -> [URL] in
            defer { folders.removeAll() }
            return folders
        }
        for folder in made { try? FileManager.default.removeItem(at: folder) }
    }
}

// MARK: Signatures

/// The box of all of `strokes`' points; null for none.
func strokeBounds(_ strokes: [[CGPoint]]) -> CGRect {
    let points = strokes.joined()
    guard let first = points.first else { return .null }
    return points.reduce(CGRect(origin: first, size: .zero)) { $0.union(CGRect(origin: $1, size: .zero)) }
}

/// A drawing far past what a signature keeps: a zigzag of 30,000 points, each 100 from the last, then
/// 1,199 scribbles of 200 points (1,200 strokes, 269,800 points).
func oversizedDrawing() -> [[CGPoint]] {
    var strokes: [[CGPoint]] = [(0..<30_000).map { CGPoint(x: Double($0) * 0.02, y: $0 % 2 == 0 ? 0 : 100) }]
    for i in 0..<1_199 {
        strokes.append((0..<200).map { CGPoint(x: Double(i % 40) * 15 + Double($0 % 2) * 10, y: Double(i / 40) * 3 + Double($0) * 0.5) })
    }
    return strokes
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
                   contents: nil, author: nil, modified: nil, color: nil, locked: false,
                   fontSize: nil, fill: nil, borderWidth: nil, restyleInPlaceOnly: false)
}

/// A 10 × 10 rectangle annotation whose top is at `y` on `page`.
func info(page: Int = 0, index: UInt32, y: CGFloat) -> AnnotationInfo {
    info(page: page, index: index, rect: CGRect(x: 0, y: y, width: 10, height: 10))
}

// MARK: Hand-made documents

/// A one-page PDF (US Letter) written here, with one form field, `signature`: a signature field that
/// holds a signature when `signed` (the engine counts the document as signed; the signature is not a
/// valid one), and an empty text field otherwise. When `damaged`, its `startxref` points past the
/// end of the file, so the engine rebuilds its cross-reference data as it opens it, and saving
/// writes the file out in full (`EditCapabilities.rewritesOnSave`).
func handMadePDF(signed: Bool, damaged: Bool) -> Data {
    let field = signed
        ? "/FT /Sig /T (signature) /V << /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange [0 0 0 0] /Contents <00> >>"
        : "/FT /Tx /T (signature)"
    let objects = [
        "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] >> >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
        "<< /Type /Annot /Subtype /Widget /Rect [100 100 300 150] /P 3 0 R \(field) >>",
    ]
    var pdf = "%PDF-1.4\n"
    var offsets: [Int] = []
    for (number, body) in objects.enumerated() {
        offsets.append(pdf.utf8.count)
        pdf += "\(number + 1) 0 obj\n\(body)\nendobj\n"
    }
    let table = pdf.utf8.count
    pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
    for offset in offsets { pdf += String(format: "%010d 00000 n \n", offset) }
    let startxref = damaged ? 9_999_999 : table
    pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(startxref)\n%%EOF\n"
    return Data(pdf.utf8)
}

// MARK: A document that fails

/// The engine document `real` is, except for the calls `failing` names, which fail once the engine has
/// made them, as a change, an undo or a redo can fail half way (`EditError.Failed`: the bridge's
/// revision has moved on all the same). It shares `real`'s engine document.
final class FailingDocument: PdfDocument, @unchecked Sendable {
    /// Which calls fail.
    enum Failing: Sendable {
        /// Every `setInfo` change.
        case setInfo
        /// Every undo.
        case undo
    }

    let failing: Failing

    init(wrapping real: PdfDocument, failing: Failing) {
        self.failing = failing
        super.init(unsafeFromHandle: real.uniffiCloneHandle())
    }

    required init(unsafeFromHandle handle: UInt64) {
        failing = .setInfo
        super.init(unsafeFromHandle: handle)
    }

    override func apply(edit: Edit, baseRevision: UInt64) throws -> EditOutcome {
        let outcome = try super.apply(edit: edit, baseRevision: baseRevision)
        if failing == .setInfo, case .setInfo = edit { throw EditError.Failed(message: "failed after the change was made") }
        return outcome
    }

    override func undo() throws -> EditOutcome {
        let outcome = try super.undo()
        if failing == .undo { throw EditError.Failed(message: "failed after the change was taken back") }
        return outcome
    }
}

/// A model of `<fixture>.pdf` whose engine document fails as `failing` says (`FailingDocument`), with a
/// fresh `UndoManager` of its own wired in that groups only what the test groups (`groupsByEvent` off).
@MainActor
func makeFailingModel(fixture: String = "sample", failing: FailingDocument.Failing) async throws -> (DocumentModel, UndoManager) {
    let document = FailingDocument(wrapping: try PdfDocument.open(bytes: try fixtureData(fixture), password: nil), failing: failing)
    let pages = (0..<document.pageCount()).compactMap { document.pageInfo(page: $0) }
    let model = DocumentModel(outcome: .open(document, pages: pages), toolStyles: isolatedToolStyles(), signatures: isolatedSignatures())
    let undoManager = UndoManager()
    undoManager.groupsByEvent = false
    model.undoManager = undoManager
    await model.settle()
    return (model, undoManager)
}

/// Hands `edits` over as one change in an undo group of its own, as one tap does, and says whether it
/// was made.
@MainActor
@discardableResult
func change(_ model: DocumentModel, _ undoManager: UndoManager, _ edits: [Edit], named name: String = Strings.actionRotate) async -> Bool {
    undoManager.beginUndoGrouping()
    let made = model.enqueue(edits, named: name, touching: nil)
    undoManager.endUndoGrouping()
    return await made.value
}
