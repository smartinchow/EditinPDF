import CoreTransferable
import EditinPDFCore
import Foundation
import UniformTypeIdentifiers

/// Some pages of a document as a PDF of their own, for the share sheet (which includes Save to Files).
/// The PDF is made when the sheet asks for it, not before. It has no password, even when the document
/// it comes from has one.
struct ExtractedPages: Transferable, Sendable {
    let document: PdfDocument
    /// The pages to extract, counting from 0, ascending.
    let pages: [UInt32]
    /// The file's name, with or without ".pdf" (`Strings.extractedFileName`).
    let fileName: String

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .pdf) { item in
            // A folder of its own, so two shares of the same name cannot meet. The share sheet reads the
            // file after this returns, so it cannot be removed here: older folders go instead.
            sweepShareFolders(olderThan: 3600)
            let folder = shareRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return SentTransferredFile(try item.write(to: folder), allowAccessingOriginalFile: false)
        }
    }

    /// Writes the PDF into `directory` and returns its URL.
    func write(to directory: URL) throws -> URL {
        let bytes = try document.extractPages(pages: pages)
        let url = directory.appendingPathComponent(safeName, isDirectory: false)
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// `fileName` as a file name: no path separators, and ending in ".pdf".
    private var safeName: String {
        let cleaned = fileName.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return cleaned.lowercased().hasSuffix(".pdf") ? cleaned : cleaned + ".pdf"
    }
}

/// The folder the files made for sharing are in, one folder to each.
private var shareRoot: URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("EditinPDFShare", isDirectory: true)
}

/// Removes the folders in `shareRoot` last changed more than `age` seconds ago (all of them for 0).
/// The app calls it with 0 at launch, when no share is under way.
func sweepShareFolders(olderThan age: TimeInterval) {
    let fm = FileManager.default
    guard let folders = try? fm.contentsOfDirectory(at: shareRoot, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
    for folder in folders {
        let changed = (try? folder.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if age <= 0 || Date().timeIntervalSince(changed) > age { try? fm.removeItem(at: folder) }
    }
}

/// Reading a file the reader picked, which may be anywhere (iCloud, another app's folder).
enum PickedFile {
    /// The most that is read, so a huge file cannot exhaust memory.
    static let sizeLimit = 500 * 1024 * 1024

    enum ReadError: Error, Equatable {
        case tooLarge
        case unreadable
    }

    /// The sentence that says why `error` stopped a file from being read.
    static func message(for error: ReadError) -> String {
        switch error {
        case .tooLarge: Strings.pickedFileTooLarge
        case .unreadable: Strings.pickedFileUnreadable
        }
    }

    /// Reads `url` with security-scoped access, off the main actor, refusing a file over `limit` bytes.
    static func read(_ url: URL, limit: Int = sizeLimit) async -> Result<Data, ReadError> {
        await Task.detached(priority: .userInitiated) { readNow(url, limit: limit) }.value
    }

    static func readNow(_ url: URL, limit: Int) -> Result<Data, ReadError> {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            // Read in pieces and stop past the limit, whatever the file says about its size.
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            var data = Data()
            while let piece = try handle.read(upToCount: 4 * 1024 * 1024), !piece.isEmpty {
                if data.count + piece.count > limit { return .failure(.tooLarge) }
                data.append(piece)
            }
            return .success(data)
        } catch {
            return .failure(.unreadable)
        }
    }
}
