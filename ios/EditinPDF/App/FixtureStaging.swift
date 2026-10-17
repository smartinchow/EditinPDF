#if DEBUG
import Foundation
import os

/// Test support, compiled into Debug builds only: the sample documents the UI tests open travel
/// inside the app, and launching it with `-openFixture <file name>` copies that one into its
/// Documents folder, where the document browser lists it. A test runner has no sanctioned way to put
/// files into an app's folder, and SwiftUI has no way for the app to open a document by itself on iOS
/// (its `openDocument` action is macOS only), so the test finds the staged file in the browser and
/// opens it from there, as a person would.
///
/// The documents are the UI tests' own `Fixtures` folder, bundled into the Debug app by
/// `project.yml`; Release has neither this type nor the files.
enum FixtureStaging {
    /// The launch argument, followed by the name of the document: `-openFixture sample.pdf`.
    static let launchArgument = "-openFixture"

    enum StagingError: Error {
        /// The name is empty or has a path in it: only the name of a bundled file is accepted.
        case notAFileName(String)
        /// No file of that name is bundled with the app.
        case notBundled(String)
    }

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "fixtures")

    /// The name of the document that `arguments` ask for; nil if they do not ask for one.
    static func requestedFixture(in arguments: [String]) -> String? {
        guard let flag = arguments.firstIndex(of: launchArgument) else { return nil }
        return arguments.indices.contains(flag + 1) ? arguments[flag + 1] : nil
    }

    /// Copies the bundled document `name` into `folder`, replacing a file of that name already
    /// there, and returns where it is now. Other files in `folder` are left alone.
    @discardableResult
    static func stage(_ name: String, from bundle: Bundle = .main, into folder: URL) throws -> URL {
        // A plain file name: nothing that could reach outside the bundle's files or the folder.
        guard !name.isEmpty, name != ".", name != "..", URL(fileURLWithPath: name).lastPathComponent == name else {
            throw StagingError.notAFileName(name)
        }
        guard let source = bundle.url(forResource: name, withExtension: nil) else {
            throw StagingError.notBundled(name)
        }
        let destination = folder.appendingPathComponent(name)
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) {
            try files.removeItem(at: destination)
        }
        try files.copyItem(at: source, to: destination)
        return destination
    }

    /// What the app does when it launches: stages the document its arguments ask for, if any, into
    /// `folder` (the app's Documents folder unless a test says otherwise). A request that cannot be
    /// met is logged and the app carries on.
    static func stageRequestedFixture(arguments: [String] = ProcessInfo.processInfo.arguments, into folder: URL? = nil) {
        guard let name = requestedFixture(in: arguments) else { return }
        guard let folder = folder ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            log.error("no Documents folder to stage \(name, privacy: .public) in")
            return
        }
        do {
            try stage(name, into: folder)
        } catch {
            log.error("could not stage \(name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
