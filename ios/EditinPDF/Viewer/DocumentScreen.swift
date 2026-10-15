import SwiftUI

/// The screen for one open document. A placeholder for now, showing the page count; the page view
/// takes its place.
struct DocumentScreen: View {
    let model: DocumentModel

    var body: some View {
        Text(Strings.pageCount(model.pageCount))
            .accessibilityIdentifier("pageCountLabel")
    }
}
