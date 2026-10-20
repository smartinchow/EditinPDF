import SwiftUI

@main
struct EditinPDFApp: App {
    init() {
        sweepShareFolders(olderThan: 0)
        #if DEBUG
        // UI tests ask for a sample document to be put in the Documents folder (see FixtureStaging).
        FixtureStaging.stageRequestedFixture()
        // And for the signature saved by an earlier run to be forgotten, so Sign starts with none.
        if ProcessInfo.processInfo.arguments.contains(FixtureStaging.forgetSignatureArgument) {
            try? SignatureStore.shared.delete()
        }
        #endif
    }

    var body: some Scene {
        // Edited in place; the system autosaves what the engine writes (see PDFFileDocument). The iOS 27
        // SDK marks this initializer and ReferenceFileDocument deprecated, but their replacements need
        // iOS 27, so the app keeps them until its minimum moves there (the build prints no warning for
        // them today).
        DocumentGroup(newDocument: { PDFFileDocument() }) { configuration in
            DocumentScreen(model: configuration.document.model,
                           documentName: configuration.fileURL?.deletingPathExtension().lastPathComponent ?? Strings.untitledDocument)
        }
    }
}
