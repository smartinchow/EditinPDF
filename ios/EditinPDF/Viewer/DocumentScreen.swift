import SwiftUI

/// The screen for one document: its pages, once it is open, with the thumbnails button in the
/// toolbar and the page indicator over the pages. A locked or unreadable document still shows the
/// placeholder page count, until the password prompt and the error message replace it.
struct DocumentScreen: View {
    let model: DocumentModel
    /// A page to jump to, for the thumbnails and search to set.
    @State private var scrollTarget: Int?
    /// Set to show the thumbnails sheet, and cleared when it closes.
    @State private var thumbnailsSheet: ThumbnailsPresentation?
    /// Made when the thumbnails are first asked for and kept while the document is on screen, so the
    /// sheet opens with its pictures the next time.
    @State private var thumbnails: ThumbnailStore?
    @Environment(\.displayScale) private var displayScale

    /// What the thumbnails sheet is shown with. The store travels in the item the sheet is presented
    /// for, instead of the sheet's content reading it from this view's state: done that way the
    /// content ran with the store still nil, though the button's action had set it just before
    /// (observed on the iOS 26.5 simulator, in a document scene).
    private struct ThumbnailsPresentation: Identifiable {
        let id = UUID()
        let store: ThumbnailStore
    }

    var body: some View {
        switch model.state {
        case .open:
            PageScrollView(model: model, scrollTarget: $scrollTarget)
                .ignoresSafeArea()
                // An overlay, not a bar: the scroll view's insets do not change when it appears.
                .overlay(alignment: .bottom) { pageIndicator }
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) { thumbnailsButton }
                }
                .sheet(item: $thumbnailsSheet) { presentation in
                    ThumbnailsSheet(model: model, store: presentation.store, scrollTarget: $scrollTarget)
                }
        case .locked, .failed:
            pageCount
        }
    }

    /// The page the reader is on and how many there are, over the bottom of the pages. Not shown
    /// for a document with no pages.
    @ViewBuilder private var pageIndicator: some View {
        if model.pageCount > 0 {
            Text(Strings.pageIndicator(current: model.currentPage + 1, count: model.pageCount))
                .font(.footnote.monospacedDigit())
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 8)
                .accessibilityIdentifier("pageIndicator")
        }
    }

    private var thumbnailsButton: some View {
        Button(action: showThumbnails) {
            Image(systemName: "square.grid.2x2")
        }
        .disabled(model.pageCount == 0)
        .accessibilityLabel(Strings.thumbnails)
        .accessibilityIdentifier("thumbnailsButton")
    }

    private func showThumbnails() {
        // Not while the sheet is already on its way up (a second tap), or a second one would replace it.
        guard thumbnailsSheet == nil, let document = model.document() else { return }
        let store = thumbnails ?? ThumbnailStore(document: document, pages: model.pages, displayScale: displayScale)
        thumbnails = store
        // The pictures the sheet opens on are drawn while it slides up, so its first rows are not
        // blank; the cells ask for the rest as they come into view.
        store.prefetch(around: model.currentPage, radius: ThumbnailsSheet.openingRadius)
        thumbnailsSheet = ThumbnailsPresentation(store: store)
    }

    /// The placeholder for a document that is not open.
    private var pageCount: some View {
        Text(Strings.pageCount(model.pageCount))
            .accessibilityIdentifier("pageCountLabel")
    }
}
