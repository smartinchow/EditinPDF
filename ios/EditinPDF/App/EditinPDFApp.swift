import SwiftUI

@main
struct EditinPDFApp: App {
    var body: some Scene {
        // Viewing, not editing: M1 never writes to the file.
        DocumentGroup(viewing: PDFFileDocument.self) { configuration in
            DocumentScreen(model: configuration.document.model)
        }
    }
}
