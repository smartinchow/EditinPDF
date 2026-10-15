import SwiftUI

/// The screen for one document: its pages, once it is open. A locked or unreadable document still
/// shows the placeholder page count, until the password prompt and the error message replace it.
struct DocumentScreen: View {
    let model: DocumentModel
    /// A page to jump to, for the thumbnails and search to set.
    @State private var scrollTarget: Int?

    var body: some View {
        switch model.state {
        case .open:
            PageScrollView(model: model, scrollTarget: $scrollTarget)
                .ignoresSafeArea()
                .overlay(alignment: .bottom) {
                    pageCount
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 8)
                }
        case .locked, .failed:
            pageCount
        }
    }

    private var pageCount: some View {
        Text(Strings.pageCount(model.pageCount))
            .accessibilityIdentifier("pageCountLabel")
    }
}
