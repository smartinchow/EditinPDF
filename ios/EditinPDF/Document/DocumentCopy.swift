import EditinPDFCore
import Foundation
import SwiftUI
import UIKit
import os

/// Why Save As made no copy.
enum CopyFailure: Error, Equatable {
    /// The bridge refused the save (`SaveError.Signed`): a signed document whose file is damaged, saving
    /// changes would rewrite it and break its signatures.
    case signed
    /// Something waiting to be added (strokes, typed text, a note) was refused, so a copy would leave it
    /// out: none is offered.
    case waitingNotAdded
    /// The document is not open, the engine could not write it, or the copy could not be written where
    /// the reader chose.
    case failed

    /// What the alert says under its title (`Strings.copyFailedTitle`).
    var message: String {
        switch self {
        case .signed: Strings.copySignedMessage
        case .waitingNotAdded: Strings.copyWaitingNotAddedMessage
        case .failed: Strings.copyFailedMessage
        }
    }
}

extension DocumentModel {
    private static let copyLog = Logger(subsystem: Diagnostics.subsystem, category: "copy")

    /// Adds what waits, through the closing path (`commitPendingInk(closing: true)`: the strokes drawn,
    /// the text box and the form field being typed in), and the note being written, as when the scene
    /// leaves (`saveNoteDraftOnLeaving`); then waits for every change, undo and redo handed over
    /// (`settle`). Strokes refused as stale while their page stayed as it was come back on the canvas,
    /// waiting (`InkInteraction.putBack`): they are handed over once more. Says whether all of it was
    /// added: false when something was refused all the same (`failure` set since, or something still
    /// waiting), so that a copy or a save would leave out what the reader sees.
    func addEverythingWaiting() async -> Bool {
        let failureBefore = failure?.id
        commitPendingInk(closing: true)
        saveNoteDraftOnLeaving()
        await settle()
        if hasPendingEdit, failure?.id == failureBefore {
            commitPendingInk(closing: true)
            await settle()
        }
        return !(hasPendingEdit || failure.map({ $0.id != failureBefore }) == true)
    }

    /// The bytes of a copy of the document as the reader sees it, for Save As and Save As: what Save
    /// writes (`PDFFileDocument.savedBytes`: the file as opened with one appended update holding
    /// every change, a password-protected file still protected by its password).
    ///
    /// What waits is added first (`addEverythingWaiting`); when some of it was refused, no copy is made
    /// (`.waitingNotAdded`): it would leave out what the reader sees. The save runs off the main actor:
    /// the bridge holds the document's lock for the whole write.
    ///
    /// Nothing tells the engine it saved, so the document stays changed, its changes unsaved in its own
    /// file: only a copy is made. Fails with `.signed` when the bridge refuses the save for the
    /// document's signatures, `.failed` when the document is not open or the engine cannot write it.
    func copyBytes() async -> Result<Data, CopyFailure> {
        guard await addEverythingWaiting() else { return .failure(.waitingNotAdded) }
        guard let document = document() else { return .failure(.failed) }
        let saved = await EditQueue.offMain { try document.save(mode: .incremental) }
        switch saved {
        case .success(let bytes):
            return .success(bytes)
        case .failure(SaveError.Signed):
            return .failure(.signed)
        case .failure(let error):
            // The engine's words stay out of the alert and, since they may quote the file, out of the readable log.
            Self.copyLog.error("making a copy failed: \(String(describing: error), privacy: .private)")
            return .failure(.failed)
        }
    }
}

/// Where Save As puts the copy it hands to the system's exporter: a folder of its own for each copy
/// (`write`), in a folder of the app's own under the temporary folder (`root`). The exporter copies the
/// file where the reader chooses; the folder is removed once it is done, saved, cancelled or failed
/// (`remove`), and whatever is left (the app stopped meanwhile) at the next launch (`sweep`). Nothing else
/// writes the copy: a plaintext copy of a protected document's changes is not left lying in the app's
/// temporary folder.
enum CopyFiles {
    /// `tmp/EditinPDFCopy`.
    static var root: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("EditinPDFCopy", isDirectory: true)
    }

    /// Writes `bytes` as `<name>.pdf` in a new folder of its own under `root`, with complete file
    /// protection, and returns the file's URL. Nothing is left behind when the write fails.
    static func write(_ bytes: Data, named name: String, under root: URL = root) throws -> URL {
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(fileName(name), isDirectory: false)
        do {
            try bytes.write(to: file, options: [.atomic, .completeFileProtection])
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return file
    }

    /// Removes the folder `file` was written in (`write`): only a folder directly under `root`.
    static func remove(_ file: URL, under root: URL = root) {
        let folder = file.deletingLastPathComponent().standardizedFileURL
        guard folder.deletingLastPathComponent().standardizedFileURL.path == root.standardizedFileURL.path else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    /// Removes everything under `root`. The app calls it at launch, when no export is under way.
    static func sweep(under root: URL = root) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for item in items { try? fm.removeItem(at: item) }
    }

    /// `name` as a file name: no path separators, and ending in ".pdf".
    static func fileName(_ name: String) -> String {
        let cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.lowercased().hasSuffix(".pdf") ? cleaned : cleaned + ".pdf"
    }
}

/// The system's exporter for a copy written by `CopyFiles`: a document picker exporting the file as a
/// copy (it makes none of its own to leave behind), presented over `presenter`. `finished` hears whether
/// the copy was saved (true) or the picker was cancelled (false), once; the file's folder is removed
/// then. Kept alive by the picker, whose delegate it is, until then.
@MainActor
final class CopyExporter: NSObject, UIDocumentPickerDelegate {
    private let file: URL
    private let finished: @MainActor (Bool) -> Void
    /// Itself, while the picker is up: the picker holds its delegate weakly.
    private var keepsItself: CopyExporter?

    /// An exporter for `file`, alive until it finishes (`present` puts it up).
    init(file: URL, finished: @escaping @MainActor (Bool) -> Void) {
        self.file = file
        self.finished = finished
        super.init()
        keepsItself = self
    }

    /// Puts up the exporter for `file` over `presenter`.
    static func present(_ file: URL, over presenter: UIViewController, finished: @escaping @MainActor (Bool) -> Void) {
        let exporter = CopyExporter(file: file, finished: finished)
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = exporter
        presenter.present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        finish(saved: true)
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        finish(saved: false)
    }

    private func finish(saved: Bool) {
        guard keepsItself != nil else { return }
        keepsItself = nil
        CopyFiles.remove(file)
        finished(saved)
    }
}

/// A view with nothing to show, whose window the document screen presents the exporter from
/// (`topViewController`).
struct PresentationAnchor: UIViewRepresentable {
    /// Where the view is kept for the screen to find.
    final class Holder {
        weak var view: UIView?

        /// The view controller at the top of the anchor's window: the one to present over.
        @MainActor var topViewController: UIViewController? {
            var top = view?.window?.rootViewController
            while let presented = top?.presentedViewController, !presented.isBeingDismissed { top = presented }
            return top
        }
    }

    let holder: Holder

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        view.isAccessibilityElement = false
        holder.view = view
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        holder.view = view
    }
}
