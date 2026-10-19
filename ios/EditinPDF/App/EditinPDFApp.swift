import SwiftUI

@main
struct EditinPDFApp: App {
    init() {
        #if DEBUG
        // UI tests ask for a sample document to be put in the Documents folder (see FixtureStaging).
        FixtureStaging.stageRequestedFixture()
        #endif
    }

    var body: some Scene {
        // Edited in place; the system autosaves what the engine writes (see PDFFileDocument). The
        // iOS 27 replacements of this initializer and of ReferenceFileDocument need iOS 27, so their
        // deprecation warnings stay.
        DocumentGroup(newDocument: { PDFFileDocument() }) { configuration in
            DocumentScreen(model: configuration.document.model,
                           documentName: configuration.fileURL?.deletingPathExtension().lastPathComponent ?? Strings.untitledDocument)
        }
    }
}
