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
    /// Optional, after `-openFixture`: the name the document is staged under instead of its own, such
    /// as a long one, for a test that needs the title to take up the navigation bar.
    static let nameArgument = "-fixtureName"
    /// Launched with this, the app forgets the signature an earlier run saved (`SignatureStore`), so a
    /// test of Sign starts with none.
    static let forgetSignatureArgument = "-forgetSignature"
    /// Launched with this, the app forgets the tools' styles an earlier run kept (`ToolStyleStore`), so
    /// a test starts with each tool's first style (a text box's size, say, which the format bar keeps).
    static let resetToolStylesArgument = "-resetToolStyles"

    enum StagingError: Error {
        /// The name is empty or has a path in it: only the name of a bundled file is accepted.
        case notAFileName(String)
        /// No file of that name is bundled with the app.
        case notBundled(String)
    }

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "fixtures")

    /// The name of the document that `arguments` ask for; nil if they do not ask for one.
    static func requestedFixture(in arguments: [String]) -> String? {
        value(of: launchArgument, in: arguments)
    }

    /// The name `arguments` ask the document to be staged under; nil to keep its own.
    static func requestedName(in arguments: [String]) -> String? {
        value(of: nameArgument, in: arguments)
    }

    private static func value(of flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag) else { return nil }
        return arguments.indices.contains(index + 1) ? arguments[index + 1] : nil
    }

    /// Whether `name` is a plain file name: nothing that could reach outside a folder.
    private static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && URL(fileURLWithPath: name).lastPathComponent == name
    }

    /// Copies the bundled document `name` into `folder`, as `stagedName` if one is given, replacing a
    /// file of that name already there, and returns where it is now. Other files in `folder` are left
    /// alone.
    @discardableResult
    static func stage(_ name: String, as stagedName: String? = nil, from bundle: Bundle = .main, into folder: URL) throws -> URL {
        // Plain file names: nothing that could reach outside the bundle's files or the folder.
        guard isFileName(name) else { throw StagingError.notAFileName(name) }
        let target = stagedName ?? name
        guard isFileName(target) else { throw StagingError.notAFileName(target) }
        guard let source = bundle.url(forResource: name, withExtension: nil) else {
            throw StagingError.notBundled(name)
        }
        let destination = folder.appendingPathComponent(target)
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
            let staged = try stage(name, as: requestedName(in: arguments), into: folder)
            // A fresh copy has no unsaved changes of an earlier run to offer (`RecoveryStore`): the copy
            // keeps the bundle's date, which can be older than a recovery copy an earlier test left.
            RecoveryStore.shared.delete(key: RecoveryStore.key(for: staged))
        } catch {
            log.error("could not stage \(name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
#endif
