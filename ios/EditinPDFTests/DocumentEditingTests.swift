import EditinPDFCore
import UIKit
import UniformTypeIdentifiers
import XCTest
@testable import EditinPDF

// The model is main-actor isolated, so the tests are too. `sample.pdf` has three pages.
@MainActor
final class DocumentEditingTests: XCTestCase {
    func testRotateThenUndoThroughTheUndoManager() async throws {
        let (m, u) = try makeModel()
        let ok = await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(ok); XCTAssertEqual(m.pages[0].rotationDegrees, 90); XCTAssertEqual(m.revision, 1)
        XCTAssertTrue(u.canUndo); XCTAssertEqual(u.undoActionName, Strings.actionRotate)
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertTrue(u.canRedo)
        u.redo(); await m.settle(); XCTAssertEqual(m.pages[0].rotationDegrees, 90)
    }

    func testUndoOfDeleteOnLastPageKeepsCurrentPageValid() async throws {
        let (m, u) = try makeModel()
        m.currentPage = 2
        await m.perform(.deletePages(pages: [2]), named: Strings.actionDelete, touching: nil)
        XCTAssertEqual(m.pageCount, 2); XCTAssertEqual(m.currentPage, 1)
        u.undo(); await m.settle(); XCTAssertEqual(m.pageCount, 3); XCTAssertLessThan(m.currentPage, 3)
    }

    func testEveryEditClearsTextSelectionAndSelectedAnnotation() async throws {
        let (m, _) = try makeModel()
        m.selection?.beginWord(page: 0, at: try firstGlyphCenter(m)); await m.selection?.waitUntilSettled()
        XCTAssertNotNil(m.selection?.selection, "a word is selected before the edit")
        m.selectedAnnotation = AnnotationRef(page: 0, index: 0)
        await m.perform(.rotatePages(pages: [1], degrees: 90), named: Strings.actionRotate, touching: [1])
        XCTAssertNil(m.selection?.selection); XCTAssertNil(m.selectedAnnotation)
    }

    func testRefusedEditShowsReasonAndLeavesUndoStackAlone() async throws {
        let (m, u) = try makeModel()
        let ok = await m.perform(.deletePages(pages: [0, 1, 2]), named: Strings.actionDelete, touching: nil)
        XCTAssertFalse(ok); XCTAssertEqual(m.failure?.message, Strings.cannotDeleteAllPages); XCTAssertEqual(m.revision, 0)
        let shown = try XCTUnwrap(m.failure)
        XCTAssertFalse(u.canUndo, "a refused change leaves nothing to undo")
        u.undo(); await m.settle(); XCTAssertEqual(m.pageCount, 3)
        XCTAssertEqual(m.revision, 0); XCTAssertEqual(m.failure?.id, shown.id, "the undo changed nothing and said nothing new")
    }

    /// The refused change left no entry behind, so Undo takes back the change before it.
    func testUndoAfterARefusedEditUndoesTheChangeBeforeIt() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        let refused = await m.perform(.deletePages(pages: [0, 1, 2]), named: Strings.actionDelete, touching: nil)
        XCTAssertFalse(refused)
        XCTAssertEqual(u.undoActionName, Strings.actionRotate)
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertEqual(m.pageCount, 3)
    }

    /// Edits tapped quickly, each worked out at the same revision, all happen when nothing between
    /// them can change what they mean.
    func testTwoRotationsQueuedTogetherBothHappen() async throws {
        let (m, u) = try makeModel()
        let first = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let second = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let (firstOK, secondOK) = await (first.value, second.value)
        XCTAssertTrue(firstOK); XCTAssertTrue(secondOK)
        XCTAssertEqual(m.pages[0].rotationDegrees, 180); XCTAssertNil(m.failure)
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0, "both were made in the same event: one undo step")
    }

    /// A point worked out before a turn of its page would land somewhere else: refused.
    func testAPointQueuedBehindARotationOfItsPageIsRefused() async throws {
        let (m, _) = try makeModel()
        let rotate = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let note = m.enqueue([.addNote(page: 0, at: Point(x: 100, y: 100), contents: "", color: RgbColor(red: 1, green: 1, blue: 0))],
                             named: Strings.actionAddAnnotation, touching: [0])
        let (rotated, added) = await (rotate.value, note.value)
        XCTAssertTrue(rotated); XCTAssertFalse(added)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
        XCTAssertTrue(m.annotationsByPage[0, default: []].isEmpty)
    }

    /// A field filled in behind a rotation has no point to move: it happens.
    func testAFieldFilledBehindARotationHappens() async throws {
        let (m, _) = try makeModel(fixture: "form")
        await m.settle()
        let field = try XCTUnwrap(m.formFields.first { $0.kind == .text && !$0.readOnly })
        let rotate = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let fill = m.enqueue([.setFieldValue(name: field.name, value: .text(text: "Hi"))], named: Strings.actionFillField, touching: nil)
        let (rotated, filled) = await (rotate.value, fill.value)
        XCTAssertTrue(rotated); XCTAssertTrue(filled)
        XCTAssertEqual(m.formFields.first { $0.name == field.name }?.value, ["Hi"])
    }

    func testUndoTappedWhileAnEditRunsUndoesThatEdit() async throws {
        let (m, u) = try makeModel()
        let job = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        u.undo()                                   // the entry was registered synchronously; its engine undo queues behind the rotate
        _ = await job.value; await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertEqual(m.revision, 2)
    }

    /// The engine keeps the last 100 changes; the undo manager keeps them all. Undoing past the
    /// engine's history finds nothing to undo there: that change is taken off quietly, no alert, and
    /// what can be redone stays.
    func testUndoingPastTheEnginesHundredChangesIsQuietAndKeepsTheRedos() async throws {
        let m = isolatedModel(bytes: try blankDocument(widthPt: 200, heightPt: 200))
        let u = UndoManager()
        m.undoManager = u
        u.groupsByEvent = false
        // As an undo manager holding more changes than the engine does (several in one group of its
        // own: typing in a field, then a tap on a checkbox): see the test after this one.
        u.levelsOfUndo = 0
        await m.settle()
        for _ in 0..<101 {
            let turned = await change(m, u, [.rotatePages(pages: [0], degrees: 90)])
            XCTAssertTrue(turned)
        }
        XCTAssertEqual(m.revision, 101)
        for _ in 0..<101 {
            u.undo()
            await m.settle()
        }
        XCTAssertNil(m.failure, "no alert")
        XCTAssertFalse(u.canUndo, "the change the engine no longer has is off the undo manager")
        XCTAssertEqual(m.revision, 201, "100 undone; the last undo changed nothing")
        XCTAssertEqual(m.pages[0].rotationDegrees, 90, "the oldest turn stays")
        var redone = 0
        while u.canRedo, redone < 200 {
            u.redo()
            await m.settle()
            redone += 1
        }
        XCTAssertEqual(redone, 100, "every change undone can be redone")
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.revision, 301)
    }

    /// The scene's undo manager keeps as many changes as the engine (its `levelsOfUndo`, set as the
    /// model adopts it): past the 100th, Undo is off, never a tap that does nothing.
    func testTheUndoManagerKeepsAsManyChangesAsTheEngine() async throws {
        let m = isolatedModel(bytes: try blankDocument(widthPt: 200, heightPt: 200))
        let u = UndoManager()
        m.undoManager = u
        XCTAssertEqual(u.levelsOfUndo, 100)
        XCTAssertEqual(DocumentModel.undoLimit, 100)
        u.groupsByEvent = false
        await m.settle()
        for _ in 0..<101 { await change(m, u, [.rotatePages(pages: [0], degrees: 90)]) }
        var undone = 0
        while u.canUndo, undone < 200 {
            u.undo()
            await m.settle()
            undone += 1
        }
        XCTAssertEqual(undone, 100, "as many as the engine keeps")
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.revision, 201, "each of them undone in the engine")
        XCTAssertEqual(m.pages[0].rotationDegrees, 90, "the oldest turn stays")
    }

    /// A change that fails half way may have changed the document (`Failed` moves the revision on), so
    /// the engine's history may no longer match the undo manager's stack: no change is left on it, as
    /// when an undo fails.
    func testAChangeThatFailsHalfWayTakesEveryChangeOffTheUndoManager() async throws {
        let (m, u) = try await makeFailingModel(failing: .setInfo)
        let turned = await change(m, u, [.rotatePages(pages: [0], degrees: 90)])
        XCTAssertTrue(turned)
        XCTAssertTrue(u.canUndo)
        let titled = await change(m, u, [.setInfo(key: "Title", value: "x")], named: "Set the title")
        XCTAssertFalse(titled)
        XCTAssertNotNil(m.failure)
        XCTAssertEqual(m.revision, 2, "the document was read again at the revision the failure left")
        XCTAssertFalse(u.canUndo, "no change is left on the undo manager")
        XCTAssertEqual(m.pages[0].rotationDegrees, 90)
    }

    /// A signed document whose file is damaged cannot be changed (saving would rewrite it and break its
    /// signatures): every tool says so in one sentence of ours. Either alone changes nothing.
    func testASignedDocumentWhoseFileIsDamagedSaysWhyNothingCanBeChanged() async throws {
        let m = isolatedModel(bytes: handMadePDF(signed: true, damaged: true))
        await m.settle()
        let capabilities = try XCTUnwrap(m.capabilities)
        XCTAssertTrue(capabilities.isSigned && capabilities.rewritesOnSave)
        XCTAssertFalse(capabilities.canEdit || capabilities.canAnnotate || capabilities.canOrganize || capabilities.canFillForms)
        XCTAssertEqual(m.signatureLock, Strings.signedDocumentDamaged)
        for tool in Tool.allCases where tool.annotates {
            XCTAssertEqual(m.refusal(of: tool), Strings.signedDocumentDamaged, "\(tool)")
        }
        XCTAssertNil(m.refusal(of: .select))
        let filled = await m.fill("signature", with: .text(text: "x"))
        XCTAssertFalse(filled)
        XCTAssertEqual(m.failure?.message, Strings.signedDocumentDamaged)
        XCTAssertTrue(OrganizeController(model: m).organizeIsRefused)

        for (signed, damaged) in [(true, false), (false, true)] {
            let other = isolatedModel(bytes: handMadePDF(signed: signed, damaged: damaged))
            await other.settle()
            XCTAssertEqual(other.capabilities?.rewritesOnSave, damaged)
            XCTAssertEqual(other.capabilities?.canAnnotate, true, "signed \(signed), damaged \(damaged)")
            XCTAssertNil(other.signatureLock)
            XCTAssertNil(other.refusal(of: .ink))
        }
    }

    /// A change handed over before the document's capabilities are read (the tools cannot tell yet
    /// that a signed, damaged document is locked) comes after that read in the queue, and is refused
    /// there with our sentence, before the engine is asked, leaving nothing on the undo manager. The
    /// save the scene makes all the same (the change marked the document edited) writes the file as
    /// it was opened, without an error.
    func testAChangeToALockedDocumentBeforeItsCapabilitiesAreReadIsRefusedAndSavesAsOpened() async throws {
        let bytes = handMadePDF(signed: true, damaged: true)
        let file = PDFFileDocument(bytes: bytes)
        let m = file.model
        let u = UndoManager()
        m.undoManager = u
        XCTAssertNil(m.capabilities, "not read yet")
        XCTAssertNil(m.refusal(of: .ink), "so nothing refuses it yet")
        let turned = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        let made = await turned.value
        await m.settle()
        XCTAssertFalse(made)
        XCTAssertEqual(m.failure?.message, Strings.signedDocumentDamaged)
        XCTAssertFalse(u.canUndo)
        let snapshot = try file.snapshot(contentType: .pdf)
        let saved = try await Task.detached { try file.savedBytes(of: snapshot.document, waitingAtMost: 1) }.value
        XCTAssertEqual(saved, bytes, "the file as it was opened, signatures and all")
    }

    /// A mark over more lines than one mark takes (the bridge's cap on its boxes) is refused before
    /// it is asked, with a sentence that says what to do.
    func testAMarkOverTooManyLinesAsksForLessText() {
        XCTAssertEqual(DocumentModel.maxMarkupBoxes, 10_000)
        XCTAssertNil(DocumentModel.markupRefusal(boxes: 1))
        XCTAssertNil(DocumentModel.markupRefusal(boxes: 10_000))
        XCTAssertEqual(DocumentModel.markupRefusal(boxes: 10_001), Strings.selectLessText)
    }

    // MARK: What an undo or a redo shifts

    /// An undo or a redo shifts what its change does, and, for a change that adds an annotation, the
    /// places of the annotations (it takes the annotation off again); no more. Strokes or a placement
    /// worked out before an undo of a mark still mean the same; a delete of an annotation does not.
    func testAnUndoShiftsWhatItsOwnChangeDoes() {
        let mark = Edit.addTextMarkup(page: 0, kind: .highlight, rects: [Rect(x: 0, y: 0, width: 10, height: 10)],
                                      color: RgbColor(red: 1, green: 1, blue: 0), contents: "")
        let ink = Edit.addInk(page: 0, strokes: [[Point(x: 0, y: 0), Point(x: 10, y: 10)]], color: RgbColor(red: 0, green: 0, blue: 0), width: 2)
        XCTAssertEqual(DocumentModel.shift(of: [mark]), [], "adding one shifts nothing")
        XCTAssertEqual(DocumentModel.undoShift(of: [mark]), [.annotations])
        XCTAssertEqual(DocumentModel.undoShift(of: [ink, ink]), [.annotations])
        XCTAssertEqual(DocumentModel.undoShift(of: [.rotatePages(pages: [0], degrees: 90)]), [.geometry])
        XCTAssertEqual(DocumentModel.undoShift(of: [.deletePages(pages: [1])]), [.pages])
        XCTAssertEqual(DocumentModel.undoShift(of: [.insertBlankPage(at: 0, widthPt: 612, heightPt: 792)]), [.pages])
        XCTAssertEqual(DocumentModel.undoShift(of: [.deleteAnnotation(page: 0, index: 0)]), [.annotations])
        XCTAssertEqual(DocumentModel.undoShift(of: [.setFieldValue(name: "a", value: .text(text: "b"))]), [])
        XCTAssertEqual(DocumentModel.undoShift(of: [.setAnnotationContents(page: 0, index: 0, contents: "x")]), [])

        var shifts = DocumentModel.Shifts()
        shifts.record(DocumentModel.undoShift(of: [mark]), at: 5)
        XCTAssertTrue(DocumentModel.canRebase([ink], workedOutAt: 4, shifts: shifts), "strokes drawn before the undo of a mark")
        XCTAssertTrue(DocumentModel.canRebase([.rotatePages(pages: [0], degrees: 90)], workedOutAt: 4, shifts: shifts))
        XCTAssertFalse(DocumentModel.canRebase([.deleteAnnotation(page: 0, index: 3)], workedOutAt: 4, shifts: shifts),
                       "a place worked out before may name no annotation, or another")
        XCTAssertFalse(DocumentModel.canRebase([.setAnnotationContents(page: 0, index: 3, contents: "x")], workedOutAt: 4, shifts: shifts))
        XCTAssertTrue(DocumentModel.canRebase([.deleteAnnotation(page: 0, index: 3)], workedOutAt: 5, shifts: shifts))
        shifts.record(DocumentModel.undoShift(of: [.rotatePages(pages: [1], degrees: 90)]), at: 6)
        XCTAssertFalse(DocumentModel.canRebase([ink], workedOutAt: 5, shifts: shifts), "points worked out before a turn")
        XCTAssertTrue(DocumentModel.canRebase([.deletePages(pages: [0])], workedOutAt: 5, shifts: shifts))
        shifts.record(DocumentModel.undoShift(of: [.deletePages(pages: [0])]), at: 7)
        XCTAssertFalse(DocumentModel.canRebase([.rotatePages(pages: [0], degrees: 90)], workedOutAt: 6, shifts: shifts))
        XCTAssertTrue(DocumentModel.canRebase([.setFieldValue(name: "a", value: .text(text: "b"))], workedOutAt: 0, shifts: shifts))
    }

    /// Restyling a text box may delete it and add it again at the end of its page's list: it moves the
    /// places after it, as a delete does (its undo too), and it names its text box by its place.
    func testARestyleShiftsAndDependsOnThePlacesOfTheAnnotations() {
        let restyle = Edit.restyleTextBox(page: 0, index: 1, fontSize: 20, color: RgbColor(red: 0, green: 0, blue: 0),
                                          fill: nil, borderWidth: 0)
        XCTAssertEqual(DocumentModel.shift(of: [restyle]), [.annotations])
        XCTAssertEqual(DocumentModel.undoShift(of: [restyle]), [.annotations])
        XCTAssertEqual(DocumentModel.dependence(of: [restyle]), [.pages, .annotations])
        var shifts = DocumentModel.Shifts()
        shifts.record(DocumentModel.shift(of: [restyle]), at: 3)
        XCTAssertFalse(DocumentModel.canRebase([.deleteAnnotation(page: 0, index: 2)], workedOutAt: 2, shifts: shifts))
        XCTAssertFalse(DocumentModel.canRebase([restyle], workedOutAt: 2, shifts: shifts))
        XCTAssertTrue(DocumentModel.canRebase([restyle], workedOutAt: 3, shifts: shifts))
    }

    /// Strokes drawn after a mark was added, and added after that mark is undone from somewhere other
    /// than the toolbar (the undo manager itself), are added: the undo moved no page and no point.
    func testStrokesAddedAfterAnUndoOfAMarkAreAdded() async throws {
        let (m, u) = try makeModel()
        let marked = await m.addShape(page: 0, draft: .rect(CGRect(x: 100, y: 100, width: 50, height: 50), oval: false))
        XCTAssertTrue(marked)
        let drawnAt = m.revision
        u.undo()
        let added = await m.addInk(page: 0, strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 200)]], drawnAt: drawnAt)
        await m.settle()
        XCTAssertTrue(added)
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "the mark undone, the strokes added")
    }

    /// Strokes refused as stale because their page was turned meanwhile cannot be added where they
    /// were drawn: the reader is told so, in words of their own.
    func testStrokesRefusedOnATurnedPageSaySo() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        let drawnAt = m.revision
        u.undo()
        var putBack = 0
        let added = await m.enqueueInk(page: 0, strokes: [[CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 200)]], drawnAt: drawnAt) {
            putBack += 1
            return true
        }.value
        await m.settle()
        XCTAssertFalse(added)
        XCTAssertEqual(putBack, 0, "not put back on a page that turned")
        XCTAssertEqual(m.failure?.message, Strings.drawingNotAdded)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)
    }

    /// Strokes refused as stale while their page stayed as it was (another page turned on the way) are
    /// not lost: put back where they were drawn, waiting, or, when they cannot be, added again for the
    /// page as it is now. No alert either way.
    func testStrokesRefusedWhileTheirPageStayedAreKept() async throws {
        let (m, u) = try makeModel()
        let strokes: [[CGPoint]] = [[CGPoint(x: 10, y: 10), CGPoint(x: 200, y: 200)]]
        let drawnAt = m.revision
        let turn = m.enqueue([.rotatePages(pages: [1], degrees: 90)], named: Strings.actionRotate, touching: [1])
        var putBack = 0
        let first = await m.enqueueInk(page: 0, strokes: strokes, drawnAt: drawnAt) {
            putBack += 1
            return true
        }.value
        _ = await turn.value
        await m.settle()
        XCTAssertFalse(first, "refused as stale: the turn was on its way when they were drawn")
        XCTAssertEqual(putBack, 1, "back on the canvas")
        XCTAssertNil(m.failure)
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty)

        let drawnAgainAt = m.revision
        let again = m.enqueue([.rotatePages(pages: [2], degrees: 90)], named: Strings.actionRotate, touching: [2])
        _ = await m.enqueueInk(page: 0, strokes: strokes, drawnAt: drawnAgainAt) { false }.value
        _ = await again.value
        await m.settle()
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.kind), [.ink], "added again, as nothing could take them back")
        u.undo(); await m.settle()
        XCTAssertTrue(m.annotationIndex.annotations(onPage: 0).isEmpty, "the drawing is the last change")
    }

    /// Text typed in a text box and refused as stale is not lost: added again when its page stayed as
    /// it was, and otherwise kept on the pasteboard, which the reader is told.
    func testTextRefusedAsStaleIsKept() async throws {
        let (m, _) = try makeModel()
        var kept: [String] = []
        m.keepOnPasteboard = { kept.append($0) }
        let typedAt = m.revision
        let turn = m.enqueue([.rotatePages(pages: [1], degrees: 90)], named: Strings.actionRotate, touching: [1])
        _ = await m.enqueueTextBox(page: 0, at: CGPoint(x: 100, y: 100), text: "Kept", workedOutAt: typedAt).value
        _ = await turn.value
        await m.settle()
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.contents), ["Kept"], "added again")
        XCTAssertTrue(kept.isEmpty)

        let before = m.revision
        let insert = m.enqueue([.insertBlankPage(at: 0, widthPt: 612, heightPt: 792)], named: Strings.actionInsertBlank, touching: nil)
        let made = await m.enqueueTextBox(page: 0, at: CGPoint(x: 100, y: 100), text: "Moved", workedOutAt: before).value
        _ = await insert.value
        await m.settle()
        XCTAssertFalse(made)
        XCTAssertEqual(m.failure?.message, Strings.typedTextCopied)
        XCTAssertEqual(kept, ["Moved"], "on the pasteboard")

        // Changed text for a text box another change numbered again: kept the same way.
        m.failure = nil
        let box = try XCTUnwrap(m.annotationIndex.annotations(onPage: 1).first)
        let readAt = m.revision
        await m.perform(.deleteAnnotation(page: 1, index: box.index), named: Strings.actionDeleteAnnotation, touching: [1])
        let changed = await m.enqueueContents(of: AnnotationRef(page: 1, index: box.index), to: "Changed", workedOutAt: readAt,
                                              keepingText: true).value
        XCTAssertFalse(changed)
        XCTAssertEqual(m.failure?.message, Strings.typedTextCopied)
        XCTAssertEqual(kept, ["Moved", "Changed"])
    }

    /// Typed text kept on the pasteboard is plain text that stays on this device: the reader did not
    /// copy it, so it is not handed to their other devices (Universal Clipboard). It pastes as text.
    func testTypedTextIsKeptOnThisDevicesPasteboardOnly() throws {
        final class Recorder: ItemPasteboard {
            var items: [[String: Any]] = []
            var options: [UIPasteboard.OptionsKey: Any] = [:]
            func setItems(_ items: [[String: Any]], options: [UIPasteboard.OptionsKey: Any]) {
                self.items = items
                self.options = options
            }
        }
        let recorder = Recorder()
        DocumentModel.keepLocally("Kept", on: recorder)
        XCTAssertEqual(recorder.items.count, 1)
        XCTAssertEqual(recorder.items.first?.count, 1, "one representation")
        XCTAssertEqual(recorder.items.first?[UTType.utf8PlainText.identifier] as? String, "Kept")
        XCTAssertEqual(recorder.options[.localOnly] as? Bool, true, "this device only")

        let pasteboard = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pasteboard.name) }
        DocumentModel.keepLocally("Kept", on: pasteboard)
        XCTAssertEqual(pasteboard.string, "Kept")
    }

    /// Whether a page is the page it was: what moves pages, adds or deletes them before it, or turns
    /// it, changes it; what happens after it, to other pages, or to annotations, does not.
    func testWhatChangesAPage() {
        XCTAssertEqual(PageEffect(of: [.deletePages(pages: [3, 1])]), PageEffect(renumbersFrom: 1))
        XCTAssertEqual(PageEffect(of: [.movePages(pages: [4, 5], to: 2)]), PageEffect(renumbersFrom: 2))
        XCTAssertEqual(PageEffect(of: [.insertBlankPage(at: 2, widthPt: 1, heightPt: 1)]), PageEffect(renumbersFrom: 2))
        XCTAssertEqual(PageEffect(of: [.rotatePages(pages: [0, 2], degrees: 90)]), PageEffect(turns: [0, 2]))
        XCTAssertEqual(PageEffect(of: [.deleteAnnotation(page: 0, index: 0)]), .none)

        var moves = PageMoves()
        moves.record(PageEffect(of: [.rotatePages(pages: [1], degrees: 90)]), at: 3)
        moves.record(PageEffect(of: [.insertBlankPage(at: 4, widthPt: 1, heightPt: 1)]), at: 5)
        moves.record(.none, at: 6)
        XCTAssertTrue(moves.leaves(0, unchangedSince: 2), "another page turned, pages added after it")
        XCTAssertFalse(moves.leaves(1, unchangedSince: 2), "turned")
        XCTAssertTrue(moves.leaves(1, unchangedSince: 3), "turned before")
        XCTAssertFalse(moves.leaves(4, unchangedSince: 4), "a page inserted in its place")
        XCTAssertFalse(moves.leaves(9, unchangedSince: 4))
        XCTAssertTrue(moves.leaves(3, unchangedSince: 4))
        moves.record(.everything, at: 8)
        XCTAssertFalse(moves.leaves(0, unchangedSince: 7), "a change not known moves every page")

        var many = PageMoves()
        for revision in 1...UInt64(PageMoves.limit + 1) { many.record(PageEffect(turns: [9]), at: revision) }
        XCTAssertFalse(many.leaves(0, unchangedSince: 0), "older than what is kept: not known")
        XCTAssertTrue(many.leaves(0, unchangedSince: 1))
    }

    /// Undo and Redo, in the toolbar and in the Edit menu, follow one rule: Undo with a change to take
    /// back or something waiting (it adds that first), Redo with a change to make again and nothing
    /// waiting.
    func testUndoAndRedoAreOfferedByOneRule() {
        XCTAssertFalse(UndoAvailability().undoEnabled)
        XCTAssertFalse(UndoAvailability().redoEnabled)
        XCTAssertTrue(UndoAvailability(canUndo: true).undoEnabled)
        XCTAssertTrue(UndoAvailability(hasPendingEdit: true).undoEnabled)
        XCTAssertTrue(UndoAvailability(canRedo: true).redoEnabled)
        XCTAssertFalse(UndoAvailability(canRedo: true, hasPendingEdit: true).redoEnabled, "not past what waits")
    }

    /// The Edit menu acts on the document in front: the last brought forward, until its screen goes;
    /// held weakly. Its Undo and Redo follow the model's reading of the undo manager and what waits,
    /// and are a field's while one outside the pages is typed in.
    func testTheEditMenuActsOnTheDocumentInFront() throws {
        let front = FrontDocument()
        let scene = NSObject()
        front.keyScene = { scene }
        var (first, _) = try makeModel()
        let (second, _) = try makeModel()
        front.show(first, in: scene)
        XCTAssertTrue(front.model === first)
        front.show(second, in: scene)
        front.leave(first)
        XCTAssertTrue(front.model === second, "the one in front stays when another goes")
        front.leave(second)
        XCTAssertNil(front.model)
        front.show(first, in: scene)
        first = DocumentModel(bytes: Data())
        XCTAssertNil(front.model, "a model gone is in front no more")

        // A field outside the pages being typed in has the menu's Undo and Redo; the editors on the
        // pages do not.
        let search = UITextField(), pages = PagesScrollView(), editor = UITextView()
        pages.addSubview(editor)
        XCTAssertFalse(FrontDocument.isOnThePages(search))
        XCTAssertTrue(FrontDocument.isOnThePages(editor))
        NotificationCenter.default.post(name: UITextView.textDidBeginEditingNotification, object: editor)
        XCTAssertFalse(front.fieldIsBeingTyped, "a text box's editor")
        NotificationCenter.default.post(name: UITextField.textDidBeginEditingNotification, object: search)
        XCTAssertTrue(front.fieldIsBeingTyped)
        NotificationCenter.default.post(name: UITextField.textDidEndEditingNotification, object: search)
        XCTAssertFalse(front.fieldIsBeingTyped)

        XCTAssertEqual(second.undoAvailability, UndoAvailability())
        second.undoStackDidChange(canUndo: true, canRedo: true, undoName: "", redoName: "")
        XCTAssertEqual(second.undoAvailability, UndoAvailability(canUndo: true, canRedo: true))
        second.pendingInkDidChange(true)
        XCTAssertTrue(second.undoAvailability.undoEnabled)
        XCTAssertFalse(second.undoAvailability.redoEnabled, "not past the strokes waiting")
    }

    /// The document in front, for the Edit menu, is the one shown in the key window's scene, not the
    /// scene that became active last: of two side by side on an iPad, the one whose window is key; none
    /// when the key window shows the document browser, or no window is key. Of several shown in one
    /// scene, the last shown. It is found again as a window becomes key, and as a command runs.
    func testTheDocumentInFrontIsTheOneInTheKeyWindowsScene() async throws {
        let (first, firstUndo) = try makeModel()
        let (second, secondUndo) = try makeModel()
        let left = NSObject(), right = NSObject(), browser = NSObject()
        let displays = [FrontDocument.Display(model: first, scene: left), FrontDocument.Display(model: second, scene: right)]
        XCTAssertTrue(FrontDocument.front(of: displays, keyScene: left) === first, "the key one, though the other came last")
        XCTAssertTrue(FrontDocument.front(of: displays, keyScene: right) === second)
        XCTAssertNil(FrontDocument.front(of: displays, keyScene: browser), "the key window shows the documents")
        XCTAssertNil(FrontDocument.front(of: displays, keyScene: nil), "no window is key")
        let both = displays + [FrontDocument.Display(model: first, scene: right)]
        XCTAssertTrue(FrontDocument.front(of: both, keyScene: right) === first, "the last shown in the key window's scene")

        // As the app keeps it: the screens shown, then the key window moving from scene to scene.
        let front = FrontDocument()
        var key: AnyObject? = left
        front.keyScene = { key }
        front.show(first, in: left)
        front.show(second, in: right)
        XCTAssertTrue(front.model === first, "the right one came last, but the left window is key")
        key = right
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: nil)
        XCTAssertTrue(front.model === second, "found again as a window becomes key")
        key = browser
        NotificationCenter.default.post(name: UIWindow.didBecomeKeyNotification, object: nil)
        XCTAssertNil(front.model, "the document browser's window is key")

        // A command finds the key window's document as it runs.
        await first.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        await second.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        key = left
        front.undo()
        XCTAssertTrue(firstUndo.canRedo, "the left one's change taken back")
        XCTAssertFalse(secondUndo.canRedo)
        await first.settle()
        XCTAssertEqual(first.pages[0].rotationDegrees, 0)
        XCTAssertEqual(second.pages[0].rotationDegrees, 90)
        front.leave(first)
        XCTAssertNil(front.model, "its screen went")
    }

    /// The Edit menu names the change its Undo and Redo make, as the system's menu did ("Undo Add
    /// Markup"), under the toolbar's rule: what waits, when something does (Undo adds it, then takes it
    /// back, and Redo waits), else the undo manager's last change. Plain while they are off.
    func testTheEditMenuNamesTheChangeUndoAndRedoMake() async throws {
        let (m, u) = try makeModel()
        func read() {
            m.undoStackDidChange(canUndo: u.canUndo, canRedo: u.canRedo, undoName: u.undoActionName, redoName: u.redoActionName)
        }
        XCTAssertEqual(m.undoAvailability.undoTitle, Strings.undo)
        XCTAssertEqual(m.undoAvailability.redoTitle, Strings.redo)
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        read()
        XCTAssertEqual(m.undoAvailability.undoTitle, Strings.undoAction(Strings.actionRotate))
        XCTAssertEqual(m.undoAvailability.redoTitle, Strings.redo, "nothing to redo")
        u.undo(); await m.settle(); read()
        XCTAssertEqual(m.undoAvailability.undoTitle, Strings.undo, "nothing left to undo")
        XCTAssertEqual(m.undoAvailability.redoTitle, Strings.redoAction(Strings.actionRotate))

        m.pendingInkDidChange(true)
        XCTAssertEqual(m.undoAvailability.undoTitle, Strings.undoAction(Strings.actionAddAnnotation), "the strokes waiting")
        XCTAssertEqual(m.undoAvailability.redoTitle, Strings.redo, "Redo waits for them")
        m.pendingInkDidChange(false)
        m.pendingTextDidChange(true, named: Strings.actionEditAnnotation)
        XCTAssertEqual(m.undoAvailability.undoTitle, Strings.undoAction(Strings.actionEditAnnotation), "a text box's text changed")
        m.pendingTextDidChange(false)
        m.pendingFieldTextDidChange(true)
        XCTAssertEqual(m.undoAvailability.undoTitle, Strings.undoAction(Strings.actionFillField))
        m.pendingFieldTextDidChange(false)
        XCTAssertEqual(m.undoAvailability.undoTitle, Strings.undo)
        XCTAssertEqual(m.undoAvailability.redoTitle, Strings.redoAction(Strings.actionRotate))
    }

    /// A note being written when the scene goes to the background is saved, handed over at once (the
    /// system saves the file as the scene goes), and the sheet goes once it is.
    func testANoteBeingWrittenIsSavedWhenTheSceneGoes() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        m.noteDraft = NoteDraft(page: 0, point: CGPoint(x: 50, y: 50), existing: nil, text: "", revision: m.revision)
        m.saveNoteDraftOnLeaving()
        XCTAssertFalse(m.isApplying, "nothing written, nothing saved")
        m.noteTextDidChange("Back soon")
        m.saveNoteDraftOnLeaving()
        XCTAssertTrue(m.isApplying, "handed over before the scene goes")
        await m.settle()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(m.annotationIndex.annotations(onPage: 0).map(\.contents), ["Back soon"])
        XCTAssertNil(m.noteDraft, "the sheet goes once it is saved")
        XCTAssertNil(m.noteText)
    }

    /// What the text box and note editors hold their text to is what the bridge takes: a note of that
    /// many characters is added; the bridge would refuse one more.
    func testTheEditorsTextLimitIsTheBridges() async throws {
        XCTAssertEqual(ShapeGeometry.maxTextLength, Int(maxTextChars()))
        XCTAssertEqual(ShapeGeometry.maxTextLength, 100_000)
        let long = String(repeating: "é", count: ShapeGeometry.maxTextLength + 5)
        let limited = ShapeGeometry.limitedText(long)
        XCTAssertEqual(limited.unicodeScalars.count, ShapeGeometry.maxTextLength)
        XCTAssertTrue(long.hasPrefix(limited))
        // Whole characters: an emoji of several scalars that does not fit is left out whole.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        let edge = String(repeating: "a", count: ShapeGeometry.maxTextLength - 2) + family
        XCTAssertEqual(ShapeGeometry.limitedText(edge), String(repeating: "a", count: ShapeGeometry.maxTextLength - 2))

        let (m, _) = try makeModel()
        let added = await m.addNote(page: 0, at: CGPoint(x: 100, y: 100), contents: limited)
        XCTAssertTrue(added)
        XCTAssertNil(m.failure)
        XCTAssertEqual(m.annotationsByPage[0]?.first?.contents?.unicodeScalars.count, ShapeGeometry.maxTextLength)
    }

    // MARK: Beyond the brief's tests

    /// Two edits made against the same revision: the second was computed for a document that has
    /// changed by the time it runs, so the bridge refuses it instead of deleting the wrong page.
    func testAnEditForAnOlderRevisionIsRefusedAsStale() async throws {
        let (m, _) = try makeModel()
        let first = m.enqueue([.deletePages(pages: [0])], named: Strings.actionDelete, touching: nil)
        let second = m.enqueue([.deletePages(pages: [0])], named: Strings.actionDelete, touching: nil)
        let (firstOK, secondOK) = await (first.value, second.value)
        XCTAssertTrue(firstOK); XCTAssertFalse(secondOK)
        XCTAssertEqual(m.pageCount, 2)
        XCTAssertEqual(m.failure?.message, Strings.documentChangedTryAgain)
    }

    func testSeveralEditsAreOneUndoStepAndOneRevision() async throws {
        let (m, u) = try makeModel()
        let ok = await m.performAll([.rotatePages(pages: [0], degrees: 90), .rotatePages(pages: [1], degrees: 180)],
                                    named: Strings.actionRotate, touching: [0, 1])
        XCTAssertTrue(ok); XCTAssertEqual(m.revision, 1)
        XCTAssertEqual(m.pages.map(\.rotationDegrees), [90, 180, 0])
        u.undo(); await m.settle()
        XCTAssertEqual(m.pages.map(\.rotationDegrees), [0, 0, 0])
    }

    func testEachChangeSaysWhichPagesAndWhetherTheGeometryMoved() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [1], degrees: 90), named: Strings.actionRotate, touching: [1])
        XCTAssertEqual(m.lastChange, PageChange(revision: 1, pages: [1], geometryChanged: true))
        u.undo(); await m.settle()
        XCTAssertEqual(m.lastChange, PageChange(revision: 2, pages: [1], geometryChanged: true))
        await m.perform(.deletePages(pages: [0]), named: Strings.actionDelete, touching: nil)
        XCTAssertEqual(m.lastChange, PageChange(revision: 3, pages: nil, geometryChanged: true))
    }

    func testTheEnginesStateIsReadOnceOpenAndAgainAfterEachEdit() async throws {
        let (m, _) = try makeModel(fixture: "annotated")
        await m.settle()
        let capabilities = try XCTUnwrap(m.capabilities)
        XCTAssertTrue(capabilities.canEdit)
        XCTAssertFalse(m.annotationsByPage.isEmpty, "the annotated fixture has annotations")
        let before = m.annotationsByPage.values.reduce(0) { $0 + $1.count }
        let page = try XCTUnwrap(m.annotationsByPage.keys.min())
        let index = try XCTUnwrap(m.annotationsByPage[page]?.first?.index)
        let ok = await m.perform(.deleteAnnotation(page: UInt32(page), index: index), named: Strings.actionDeleteAnnotation, touching: [page])
        XCTAssertTrue(ok)
        XCTAssertEqual(m.annotationsByPage.values.reduce(0) { $0 + $1.count }, before - 1)
    }

    func testFormFieldsAreReadOnOpen() async throws {
        let (m, _) = try makeModel(fixture: "form")
        await m.settle()
        XCTAssertFalse(m.formFields.isEmpty)
    }

    func testIsApplyingLastsUntilTheQueueIsEmpty() async throws {
        let (m, _) = try makeModel()
        await m.settle()
        let job = m.enqueue([.rotatePages(pages: [0], degrees: 90)], named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(m.isApplying)
        _ = await job.value; await m.settle()
        XCTAssertFalse(m.isApplying)
    }

    /// An undo the engine fails at (here once it has taken the change back, as it can) means its history
    /// and the undo manager's stack no longer match: the reader is told, and the stack is emptied.
    func testAFailingUndoShowsItAndClearsTheUndoStack() async throws {
        let (m, u) = try await makeFailingModel(failing: .undo)
        for _ in 0..<2 { await change(m, u, [.rotatePages(pages: [0], degrees: 90)]) }
        u.undo(); await m.settle()
        XCTAssertNotNil(m.failure)
        XCTAssertFalse(u.canUndo); XCTAssertFalse(u.canRedo)
        XCTAssertEqual(m.revision, 3, "the document was read again at the revision the failure left")
    }

    /// An undo the engine has no step for (its history moved without the model here; past its 100
    /// changes in use) is no failure: only that change goes, quietly.
    func testAnUndoTheEngineHasNoStepForIsQuiet() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        _ = try XCTUnwrap(m.document()).undo()
        u.undo(); await m.settle()
        XCTAssertNil(m.failure)
        XCTAssertFalse(u.canUndo); XCTAssertFalse(u.canRedo)
    }

    func testTheToolbarsUndoAndRedoGoThroughTheUndoManager() async throws {
        let (m, u) = try makeModel()
        await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        m.undo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 0); XCTAssertTrue(u.canRedo)
        m.redo(); await m.settle()
        XCTAssertEqual(m.pages[0].rotationDegrees, 90)
    }

    func testAnEditWithoutAnUndoManagerStillApplies() async throws {
        let m = DocumentModel(bytes: try fixtureData("sample"))
        let ok = await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertTrue(ok); XCTAssertEqual(m.pages[0].rotationDegrees, 90)
    }

    func testAnEditOnADocumentThatIsNotOpenFailsQuietly() async throws {
        let m = DocumentModel(bytes: Data("garbage".utf8))
        let ok = await m.perform(.rotatePages(pages: [0], degrees: 90), named: Strings.actionRotate, touching: [0])
        XCTAssertFalse(ok); XCTAssertNil(m.capabilities)
    }

    // MARK: The queue

    func testTheQueueRunsJobsInOrderOffTheMainThread() async throws {
        let queue = EditQueue()
        let log = OrderLog()
        async let a: Bool = queue.run { OrderLog.pause(); log.append(1); return Thread.isMainThread }
        async let b: Bool = queue.run { log.append(2); return Thread.isMainThread }
        let (onMainA, onMainB) = try await (a, b)
        XCTAssertFalse(onMainA); XCTAssertFalse(onMainB)
        XCTAssertEqual(log.values.sorted(), [1, 2])
        // Submitted synchronously, so their order is the order of submission.
        let first = queue.submit { await Task.detached { OrderLog.pause(); log.append(3) }.value }
        let second = queue.submit { log.append(4) }
        await first.value; await second.value
        XCTAssertEqual(Array(log.values.suffix(2)), [3, 4])
    }

    func testAFailingJobDoesNotStopTheQueue() async throws {
        let queue = EditQueue()
        do {
            _ = try await queue.run { () throws -> Int in throw EditError.WouldRemoveAllPages }
            XCTFail("the job threw")
        } catch {}
        let value = try await queue.run { 7 }
        XCTAssertEqual(value, 7)
    }

    // MARK: What a refused edit says

    func testEveryRefusalIsOurSentenceNeverTheEngines() {
        let engineText = "ENGINE-TEXT"
        let cases: [(EditError, String)] = [
            (.ReadOnly(message: engineText), Strings.editNotAllowed),
            (.NotPermitted(message: engineText), Strings.editNotAllowed),
            (.WouldRemoveAllPages, Strings.cannotDeleteAllPages),
            (.Invalid(message: engineText), ""),
            (.Stale(current: 4), Strings.documentChangedTryAgain),
            (.SourceNeedsPassword, Strings.insertSourceLocked),
            (.SourceUnreadable(message: engineText), Strings.insertSourceUnreadable),
            (.SourceNotPermitted, Strings.insertSourceNotPermitted),
            (.NothingToUndo, ""),
            (.NothingToRedo, ""),
            (.Failed(message: engineText), ""),
        ]
        for (error, message) in cases {
            let failure = EditFailure(error)
            XCTAssertEqual(failure.title, Strings.editFailed, "\(error)")
            XCTAssertEqual(failure.message, message, "\(error)")
            XCTAssertFalse(failure.message.contains(engineText), "\(error)")
        }
        let other = EditFailure(CocoaError(.fileReadUnknown))
        XCTAssertEqual(other.title, Strings.editFailed); XCTAssertEqual(other.message, "")
    }

    // MARK: The reader's page follows its content

    func testDeletingAnEarlierPageKeepsTheReaderOnTheSamePage() async throws {
        let (m, u) = try makeModel()
        m.currentPage = 2
        await m.perform(.deletePages(pages: [0]), named: Strings.actionDelete, touching: nil)
        XCTAssertEqual(m.currentPage, 1, "still on \"Page three\", now the second page")
        u.undo(); await m.settle()
        XCTAssertEqual(m.pageCount, 3)
    }

    func testMovingPagesKeepsTheReaderOnTheSamePage() async throws {
        let (m, _) = try makeModel()
        m.currentPage = 0
        await m.perform(.movePages(pages: [0], to: 2), named: Strings.actionMove, touching: nil)
        XCTAssertEqual(m.currentPage, 2)
        await m.perform(.insertBlankPage(at: 0, widthPt: 612, heightPt: 792), named: Strings.actionInsertBlank, touching: nil)
        XCTAssertEqual(m.currentPage, 3)
    }
}

/// Numbers appended from any thread, in the order they arrived.
private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [Int] = []
    var values: [Int] { lock.withLock { _values } }
    func append(_ value: Int) { lock.withLock { _values.append(value) } }
    /// Holds the thread for 50 ms, as slow engine work would. (A function of its own: the compiler
    /// refuses `Thread.sleep` straight in an async context.)
    static func pause() { Thread.sleep(forTimeInterval: 0.05) }
}
