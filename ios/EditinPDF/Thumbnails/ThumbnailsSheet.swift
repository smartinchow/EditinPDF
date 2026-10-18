import EditinPDFCore
import SwiftUI

/// The pages of the open document as small pictures in a grid, each with its number. Tapping one
/// sets `scrollTarget` to that page, for the viewer to jump to, and closes the sheet.
///
/// The grid opens at the page the reader was on, and outlines it. Each picture is asked of `store`
/// as its cell comes into view, and given up as the cell goes away, so only what is in or near the
/// view is drawn; until its picture is there a cell shows a blank page of the right shape.
///
/// It follows changes to the document while it is up: the grid has the model's pages, and the cells
/// in view are drawn again when the store moves on to the new revision.
struct ThumbnailsSheet: View {
    let model: DocumentModel
    let store: ThumbnailStore
    @Binding var scrollTarget: Int?

    @Environment(\.dismiss) private var dismiss
    /// The page the reader was on when the sheet opened: the page that is outlined, and the one the
    /// grid opens at. It is kept for as long as the sheet is up, and not read from
    /// `model.currentPage` again: that moves the moment a page is tapped, and when the jump is held
    /// back by the end of a document of short pages it moves to a different page than the one tapped.
    @State private var openedOn: Int

    init(model: DocumentModel, store: ThumbnailStore, scrollTarget: Binding<Int?>) {
        self.model = model
        self.store = store
        _scrollTarget = scrollTarget
        _openedOn = State(initialValue: model.currentPage)
    }

    /// How many pages either side of the one the sheet opens on are drawn before it is shown: about
    /// what the first screen of the grid holds, on a phone and on a tablet.
    static let openingRadius = 12

    /// As many columns as fit, each from 96 to 120 points wide: the pictures are drawn 120 points
    /// wide, so they are never stretched.
    private static let columns = [GridItem(.adaptive(minimum: 96, maximum: 120), spacing: 16, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: Self.columns, spacing: 20) {
                        ForEach(0..<model.pageCount, id: \.self) { page in
                            ThumbnailCell(page: page, aspectRatio: model.pages[page].thumbnailAspectRatio,
                                          isOpenedOn: page == openedOn, store: store) {
                                scrollTarget = page
                                dismiss()
                            }
                        }
                    }
                    .padding(16)
                }
                .accessibilityIdentifier("thumbnailsGrid")
                // Opens at the page the reader is on, in the middle of the sheet, once the grid has been
                // laid out. A position given up front (`scrollPosition(id:)`) left the page at the bottom
                // edge of an iPad's form sheet (observed on the iOS 26.5 simulator).
                .task {
                    await Task.yield()
                    proxy.scrollTo(openedOn, anchor: .center)
                }
            }
            .background(Color(.secondarySystemBackground))
            // A document scene puts its Back button on every navigation bar inside it (observed on
            // the iOS 26.5 simulator); in the sheet it only closes the sheet, as Done does.
            .navigationBarBackButtonHidden(true)
            .navigationTitle(Strings.thumbnails)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.done) { dismiss() }
                        .accessibilityIdentifier("thumbnailsDoneButton")
                }
            }
        }
    }
}

/// One page in the grid: its picture, on blank paper of the page's shape, and its number.
private struct ThumbnailCell: View {
    let page: Int
    let aspectRatio: CGFloat
    /// Whether this is the page the sheet opened on.
    let isOpenedOn: Bool
    let store: ThumbnailStore
    let select: () -> Void
    /// Whether the cell is in or near the view, as `onAppear` and `onDisappear` say. Its picture is
    /// only part of the cell while it is: a lazy grid may keep a cell after it has scrolled away
    /// (iOS 17 is reported to), and a picture held there is held outside the store's bounded cache,
    /// so what the grid holds could grow with the document instead of staying within the cache. The
    /// picture stays in the cache, so it is back at once when the cell returns.
    @State private var isOnScreen = false

    var body: some View {
        Button(action: select) {
            VStack(spacing: 6) {
                paper
                Text(Strings.pageNumber(page + 1))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isOpenedOn ? Color.accentColor : Color.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Strings.thumbnailLabel(page: page + 1))
        .accessibilityAddTraits(isOpenedOn ? .isSelected : [])
        .accessibilityIdentifier("thumbnail-\(page)")
        .onAppear {
            isOnScreen = true
            store.prefetch(page..<page + 1)
        }
        .onDisappear {
            isOnScreen = false
            store.cancelPrefetch(page..<page + 1)
        }
        // The document changed while the sheet is up: the store dropped every picture, and the
        // cells in view ask for theirs again, of the new revision.
        .onChange(of: store.revision) {
            if isOnScreen { store.prefetch(page..<page + 1) }
        }
    }

    /// Reading the picture from the store is what makes SwiftUI draw this cell again when it arrives.
    private var paper: some View {
        Rectangle()
            .fill(.white)
            // Only the paper casts the shadow, not the picture and the outline over it.
            .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                // Not read while the cell is off screen, so such a cell is not redrawn as pictures
                // arrive either.
                if isOnScreen, let image = store.image(for: page) {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                }
            }
            .overlay {
                if isOpenedOn {
                    Rectangle().strokeBorder(Color.accentColor, lineWidth: 3)
                }
            }
    }
}

private extension PageInfo {
    /// The page's width over its height, for the blank paper shown before its picture is there: that
    /// of a US Letter page when the engine reports a size that cannot be used (as the viewer does),
    /// and no more extreme than 1 to 4 either way (the store draws no page taller than that), so one
    /// odd page cannot make a row of the grid enormous.
    var thumbnailAspectRatio: CGFloat {
        guard widthPt.isFinite, heightPt.isFinite, widthPt > 0, heightPt > 0 else { return 612.0 / 792.0 }
        let limit = CGFloat(ThumbnailStore.tallestInWidths)
        return min(max(widthPt / heightPt, 1 / limit), limit)
    }
}
