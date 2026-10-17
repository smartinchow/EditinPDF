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
        // Viewing, not editing: M1 never writes to the file.
        DocumentGroup(viewing: PDFFileDocument.self) { configuration in
            DocumentScreen(model: configuration.document.model)
        }
    }
}
