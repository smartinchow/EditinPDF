import SwiftUI

@main
struct EditinPDFApp: App {
    init() {
        sweepShareFolders(olderThan: 0)
        // Copies Save a Copy left for an exporter the app did not see finish (`CopyFiles`).
        CopyFiles.sweep()
        // Recovery copies of documents not opened again for a month (`RecoveryStore`).
        RecoveryStore.shared.sweep(olderThan: RecoveryStore.maximumAge)
        #if DEBUG
        // UI tests ask for a sample document to be put in the Documents folder (see FixtureStaging).
        FixtureStaging.stageRequestedFixture()
        // And for the signature saved by an earlier run to be forgotten, so Sign starts with none.
        if ProcessInfo.processInfo.arguments.contains(FixtureStaging.forgetSignatureArgument) {
            try? SignatureStore.shared.delete()
        }
        // And for the tools' styles an earlier run kept to be forgotten, so each tool starts with its first.
        if ProcessInfo.processInfo.arguments.contains(FixtureStaging.resetToolStylesArgument) {
            ToolStyleStore.forgetAll()
        }
        #endif
    }

    var body: some Scene {
        // Edited in place, and written only by Save (see PDFFileDocument and DocumentScreen). The iOS 27
        // SDK marks this initializer and ReferenceFileDocument deprecated, but their replacements need
        // iOS 27, so the app keeps them until its minimum moves there (the build prints no warning for
        // them today).
        DocumentGroup(newDocument: { PDFFileDocument() }) { configuration in
            let model = configuration.document.model
            DocumentScreen(model: model,
                           documentName: configuration.fileURL?.deletingPathExtension().lastPathComponent ?? Strings.untitledDocument,
                           fileURL: configuration.fileURL)
                // A document the scene replaces (the file changed on disk, another version restored)
                // has a model of its own: the screen is made again for it, its pages' controller and
                // its state with it. The model is kept for the file's life (`PDFFileDocument.model`),
                // so nothing else makes the screen again.
                .id(ObjectIdentifier(model))
        }
        .commands {
            UndoRedoCommands()
            SaveCommands()
        }
    }
}
