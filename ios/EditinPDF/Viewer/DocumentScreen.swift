import SwiftUI

/// The screen for one document: its pages, once it is open, with the search and thumbnails buttons
/// in the toolbar (and, while text is selected, a Copy button before them), and the page indicator
/// (and, while a search has hits, the bar to move between them) over the pages. A locked or
/// unreadable document still shows the placeholder page count, until the password prompt and the
/// error message replace it.
struct DocumentScreen: View {
    let model: DocumentModel
    /// A page to jump to, for the thumbnails and search to set.
    @State private var scrollTarget: Int?
    /// A box to bring into view on that page, for search to set along with it.
    @State private var revealRect: PageRect?
    /// Whether the search sheet is up. The search itself is the model's, so it is the same one each
    /// time the sheet opens.
    @State private var showsSearch = false
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
            PageScrollView(model: model, scrollTarget: $scrollTarget, revealRect: $revealRect,
                           highlights: model.search?.highlightsByPage ?? [:],
                           activeHighlight: model.search?.activeHighlight,
                           selection: model.selection?.pageRects)
                .ignoresSafeArea()
                // An overlay, not a bar: the scroll view's insets do not change when it appears.
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        searchHitBar
                        pageIndicator
                    }
                }
                .toolbar {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        copyButton
                        searchButton
                        thumbnailsButton
                    }
                }
                .sheet(item: $thumbnailsSheet) { presentation in
                    ThumbnailsSheet(model: model, store: presentation.store, scrollTarget: $scrollTarget)
                }
                .sheet(isPresented: $showsSearch) {
                    if let search = model.search {
                        SearchSheet(search: search, scrollTarget: $scrollTarget, revealRect: $revealRect)
                    }
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

    /// Moves between the hits of a search and ends it; only while there are hits.
    @ViewBuilder private var searchHitBar: some View {
        if let search = model.search, !search.hits.isEmpty {
            SearchHitBar(search: search, scrollTarget: $scrollTarget, revealRect: $revealRect)
        }
    }

    /// Copies the selected text: the same as the menu over the selection, for whoever cannot reach it.
    /// Only while text is selected.
    @ViewBuilder private var copyButton: some View {
        if let selection = model.selection, selection.selection != nil {
            Button {
                selection.copySelection()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .accessibilityLabel(Strings.copy)
            .accessibilityIdentifier("copyButton")
        }
    }

    private var searchButton: some View {
        Button {
            showsSearch = true
        } label: {
            Image(systemName: "magnifyingglass")
        }
        .disabled(model.pageCount == 0)
        .accessibilityLabel(Strings.search)
        .accessibilityIdentifier("searchButton")
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
