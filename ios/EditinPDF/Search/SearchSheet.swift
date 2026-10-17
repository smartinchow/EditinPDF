import EditinPDFCore
import SwiftUI

/// The search: a field for the words, and the places they are found in the document, each with its
/// page and the text around it. Typing searches (a moment after the last key); tapping a result
/// makes it the active hit, sets `scrollTarget` to its page for the viewer to jump to, and closes
/// the sheet, so the page is on show with the hit highlighted.
///
/// The words and the results belong to the document's `SearchController`, not to the sheet: closing
/// the sheet leaves the highlights in the viewer, and opening it again shows the same results.
struct SearchSheet: View {
    @Bindable var search: SearchController
    @Binding var scrollTarget: Int?

    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldIsFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                field
                results
            }
            .background(Color(.systemBackground))
            // A document scene puts its Back button on every navigation bar inside it (observed on
            // the iOS 26.5 simulator, as in the thumbnails sheet); here it only closes the sheet, as
            // Done does.
            .navigationBarBackButtonHidden(true)
            .navigationTitle(Strings.search)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.done) { dismiss() }
                        .accessibilityIdentifier("searchDoneButton")
                }
            }
        }
        // A new search starts with the keyboard up; coming back to results does not hide them behind it.
        .task {
            await Task.yield()
            if search.query.isEmpty { fieldIsFocused = true }
        }
    }

    /// The field, with a progress indicator at its end while a search is under way.
    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(Strings.searchPlaceholder, text: $search.query)
                .focused($fieldIsFocused)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                // Results come as the words are typed; the key only gets the keyboard out of their way.
                .onSubmit { fieldIsFocused = false }
                .accessibilityIdentifier("searchField")
            if search.isSearching {
                ProgressView()
                    .accessibilityIdentifier("searchProgress")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// The hits; or, when there are none, a line saying nothing matched, once the search is done.
    @ViewBuilder private var results: some View {
        if search.hits.isEmpty {
            ZStack {
                if search.foundNothing {
                    Text(Strings.searchNoMatches)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                        .accessibilityIdentifier("searchNoMatches")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List {
                ForEach(Array(search.hits.enumerated()), id: \.offset) { index, hit in
                    row(index: index, hit: hit)
                }
            }
            .listStyle(.plain)
            .scrollDismissesKeyboard(.interactively)
            .accessibilityIdentifier("searchResults")
            // The note stays in view, not at the end of a thousand rows.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if search.isTruncated { truncatedNote }
            }
        }
    }

    private func row(index: Int, hit: SearchHit) -> some View {
        let isActive = index == search.activeIndex
        let page = Int(hit.page) + 1
        return Button {
            select(index)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(Strings.searchHitPage(page))
                    .font(.caption)
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(hit.snippet)
                    .lineLimit(2)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // The whole row takes the tap, not only its text.
            .contentShape(Rectangle())
        }
        .accessibilityLabel(Strings.searchHitLabel(page: page, snippet: hit.snippet))
        .accessibilityAddTraits(isActive ? .isSelected : [])
        .accessibilityIdentifier("searchHit-\(index)")
    }

    private var truncatedNote: some View {
        Text(Strings.searchTruncated(limit: SearchController.hitLimit))
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .accessibilityIdentifier("searchTruncatedNote")
    }

    /// Makes hit `index` the active one and jumps to its page.
    private func select(_ index: Int) {
        guard search.hits.indices.contains(index) else { return }
        search.activeIndex = index
        scrollTarget = Int(search.hits[index].page)
        dismiss()
    }
}
