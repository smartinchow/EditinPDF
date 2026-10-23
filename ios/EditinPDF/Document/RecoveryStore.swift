import CryptoKit
import Foundation
import os

/// Where the unsaved changes of a document are kept while it is open, in case the app is stopped
/// before the reader chooses Save or Discard: iOS can end an app in the background, and a scene can be
/// closed from the app switcher or a window's close button without a word to the app.
///
/// One file per document, `Application Support/Recovery/<key>.pdf`, the key a hash of the file's path
/// (`key(for:)`): the document as the engine holds it, unsaved changes and all (its incremental save,
/// so a password-protected file's copy keeps its password). Written with complete file protection and
/// kept out of backups; never written to the document's own file. Nothing of the document is logged.
///
/// The copy is offered when the same file opens again, if it is newer than the file (`copy(key:newerThan:)`);
/// it goes on Save, on Discard, once Save As has saved a copy, and when the offer is declined; copies left
/// longer than `maximumAge` are swept at launch.
struct RecoveryStore: Sendable {
    /// The folder the copies are kept in.
    let directory: URL

    /// How long a copy is kept when its document is never opened again: 30 days.
    static let maximumAge: TimeInterval = 30 * 24 * 3600

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "recovery")

    /// The app's store: `Application Support/Recovery`.
    static var shared: RecoveryStore {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return RecoveryStore(directory: support.appendingPathComponent("Recovery", isDirectory: true))
    }

    /// The key of the document at `fileURL`: a SHA-256 of its standardized path, with symbolic links
    /// resolved, so the same file gives the same key from one launch to the next. The path itself is
    /// not kept anywhere.
    static func key(for fileURL: URL) -> String {
        let path = fileURL.standardizedFileURL.resolvingSymlinksInPath().path
        return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Where the copy for `key` is kept.
    func url(key: String) -> URL {
        directory.appendingPathComponent(key, isDirectory: false).appendingPathExtension("pdf")
    }

    /// Writes `data` as the copy for `key`, replacing the one there: whole or not at all, with complete
    /// file protection, kept out of backups (the folder and the file).
    func write(_ data: Data, key: String) throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: directory.path) {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.protectionKey: FileProtectionType.complete])
            var folder = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
        var file = url(key: key)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try file.setResourceValues(values)
    }

    /// The copy for `key`, when there is one written after `date` (any, for nil); nil otherwise.
    func copy(key: String, newerThan date: Date?) -> URL? {
        let file = url(key: key)
        guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
              values.isRegularFile == true else { return nil }
        if let date, let written = values.contentModificationDate, written <= date { return nil }
        return file
    }

    /// Removes the copy for `key`, if there is one.
    func delete(key: String) {
        try? FileManager.default.removeItem(at: url(key: key))
    }

    /// Removes the copies last written more than `age` seconds before `now`. The app calls it at launch.
    func sweep(olderThan age: TimeInterval, now: Date = Date()) {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let written = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if now.timeIntervalSince(written) > age {
                do { try fm.removeItem(at: item) } catch { Self.log.error("a stale recovery copy could not be removed") }
            }
        }
    }
}
