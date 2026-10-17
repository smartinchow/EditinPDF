import SwiftUI

/// The screen for one document: its pages, once it is open, with the search and thumbnails buttons
/// in the toolbar (and, while text is selected, a Copy button before them), and the page indicator
/// (and, while a search has hits, the bar to move between them) over the pages. A document that is
/// locked has no pages to show yet: the prompt for its password (`PasswordSheet`) is over a blank
/// screen until it is unlocked. One that could not be read has an alert saying so, whose button
/// closes it.
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
    /// Closes the document, back to the document browser. It is read here, not in the password
    /// prompt or the alert, where `dismiss` would only close those.
    @Environment(\.dismiss) private var closeDocument
    /// Set once the alert about a file that could not be opened has been answered. The document is
    /// failed for good, so without this the alert would be put up again as soon as it went away,
    /// while the document is closing (UIKit logs an attempt to present on a view that is leaving).
    @State private var failureAnswered = false

    /// What the thumbnails sheet is shown with. The store travels in the item the sheet is presented
    /// for, instead of the sheet's content reading it from this view's state: done that way the
    /// content ran with the store still nil, though the button's action had set it just before
    /// (observed on the iOS 26.5 simulator, in a document scene).
    private struct ThumbnailsPresentation: Identifiable {
        let id = UUID()
        let store: ThumbnailStore
    }

    var body: some View {
        content
            // Over whatever is behind them, so the prompt and the alert are there as soon as the state
            // is, and the prompt goes when the password opens the document. Nothing closes the prompt
            // but Cancel (which closes the document, and it with it) and the password.
            .sheet(isPresented: .constant(isLocked)) {
                PasswordSheet(model: model) { closeDocument() }
            }
            .alert(Strings.fileCouldNotBeOpened, isPresented: showsFailure) {
                // The system alert does not pass the identifier on to its button (observed on the iOS 26.5
                // simulator), so the UI test finds the button as the alert's only one; it is named here for
                // when the alert does.
                Button(Strings.close) { closeDocument() }
                    .accessibilityIdentifier("closeDocumentButton")
            } message: {
                if let detail = failureDetail { Text(detail) }
            }
    }

    /// Whether the document is waiting for its password.
    private var isLocked: Bool {
        if case .locked = model.state { true } else { false }
    }

    /// Whether the document could not be opened.
    private var isFailed: Bool {
        if case .failed = model.state { true } else { false }
    }

    /// Whether the alert about a document that could not be opened is up: from the moment the
    /// document fails until the alert's button has been pressed.
    private var showsFailure: Binding<Bool> {
        Binding(
            get: { isFailed && !failureAnswered },
            set: { isShown in if !isShown { failureAnswered = true } }
        )
    }

    /// The engine's explanation of why the document could not be opened, if it gave one.
    private var failureDetail: String? {
        if case .failed(let detail) = model.state { detail } else { nil }
    }

    @ViewBuilder private var content: some View {
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
            // Nothing to show: the prompt or the alert is what there is to see.
            Color(.systemBackground)
                .ignoresSafeArea()
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
}
