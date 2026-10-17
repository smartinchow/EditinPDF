import SwiftUI

/// Over the pages while a search has hits: which one is on show, and buttons for the previous and
/// the next, which wrap around, and one to end the search. Moving to a hit takes the viewer to it,
/// by setting `scrollTarget` and `revealRect`, as picking it in the sheet does. Ending the search
/// empties the query, which takes the highlights off the pages.
struct SearchHitBar: View {
    let search: SearchController
    @Binding var scrollTarget: Int?
    @Binding var revealRect: PageRect?

    var body: some View {
        HStack(spacing: 0) {
            button("chevron.up", label: Strings.searchPrevious, id: "searchPreviousButton") {
                show(search.previous())
            }
            Text(Self.position(of: search))
                .font(.footnote.monospacedDigit())
                .padding(.horizontal, 4)
                .accessibilityIdentifier("searchPosition")
            button("chevron.down", label: Strings.searchNext, id: "searchNextButton") {
                show(search.next())
            }
            button("xmark", label: Strings.searchEnd, id: "searchEndButton") {
                search.query = ""
            }
        }
        .padding(.horizontal, 4)
        .background(.regularMaterial, in: Capsule())
    }

    private func button(_ symbol: String, label: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 44, height: 40)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier(id)
    }

    /// Which hit is on show and how many there are: "3 of 12", or "3 of 1,000+" when the search stopped
    /// at the most hits it gives and there may be more.
    static func position(of search: SearchController) -> String {
        let current = (search.activeIndex ?? 0) + 1
        return search.isTruncated
            ? Strings.searchPositionTruncated(current: current, count: search.hits.count)
            : Strings.searchPosition(current: current, count: search.hits.count)
    }

    /// Takes the viewer to the hit that was just made the active one.
    private func show(_ target: PageRect?) {
        guard let target else { return }
        scrollTarget = target.page
        revealRect = target
    }
}
