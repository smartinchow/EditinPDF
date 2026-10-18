import SwiftUI

/// The screen for one document: its pages, once it is open, with Undo and Redo at the leading end of
/// the toolbar and the search and thumbnails buttons at the trailing end (and, while text is selected,
/// a Copy button before them), and the page indicator (and, while a search has hits, the bar to move
/// between them) over the pages. The pages and the thumbnails follow every change, undo and redo.
///
/// A document that is locked has no pages to show yet: the prompt for its password (`PasswordSheet`)
/// comes up over a screen that says it is locked. Cancel puts the prompt away and leaves that screen,
/// whose Enter Password button brings the prompt back. One that could not be read has an alert saying
/// so, and once the alert is answered the screen says the same, for as long as it is still there.
///
/// Neither relies on closing the document from inside it, which `dismiss` does on iOS 26 but is
/// reported not to do on iOS 17 and 18: with the prompt or the alert put away, the system's own way
/// back to the documents, in the navigation bar, is always there.
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
    /// The scene's undo manager, handed to the model, which registers each change with it.
    @Environment(\.undoManager) private var undoManager
    /// Whether the undo manager has something to undo, and to redo. It is not observable, so these are
    /// read again whenever it says its stacks moved.
    @State private var canUndo = false
    @State private var canRedo = false
    /// Whether a change has been in the making long enough to show a spinner by the page indicator.
    @State private var showsProgress = false
    /// Closes the document, back to the document browser, on the iOS versions where `dismiss` does
    /// that for a document scene (iOS 26 does; 17 and 18 are reported not to). Only the alert about a
    /// file that could not be opened uses it, as a shortcut: the screen behind the alert does not
    /// depend on it. It is read here, not in the alert, where `dismiss` would only close the alert.
    @Environment(\.dismiss) private var closeDocument
    /// Whether the password prompt of a locked document is up: from the start, until Cancel puts it
    /// away; Enter Password brings it back. The prompt goes when the document opens, whatever this says.
    @State private var promptIsUp = true
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
            .onAppear { adoptUndoManager() }
            .onChange(of: undoManager) { adoptUndoManager() }
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidCloseUndoGroup)) { readUndoState($0) }
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidUndoChange)) { readUndoState($0) }
            .onReceive(NotificationCenter.default.publisher(for: .NSUndoManagerDidRedoChange)) { readUndoState($0) }
            // A change the engine refused takes its entry off the undo manager, which posts nothing:
            // read again once each change, undo or redo is done.
            .onChange(of: model.isApplying) {
                readUndoState(nil)
                showsProgress = false
            }
            // Only a change that takes a while shows that it is being made, so quick ones do not flash.
            .task(id: model.isApplying) {
                guard model.isApplying else { return }
                try? await Task.sleep(for: .milliseconds(300))
                if !Task.isCancelled, model.isApplying { showsProgress = true }
            }
            // Over whatever is behind them, so the prompt and the alert are there as soon as the state
            // is, and the prompt goes when the password opens the document. Nothing else closes the
            // prompt but Cancel (it cannot be swiped away).
            .sheet(isPresented: showsPasswordPrompt) {
                PasswordSheet(model: model) { promptIsUp = false }
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

    /// Hands the scene's undo manager to the model, and shows what it can undo and redo.
    private func adoptUndoManager() {
        model.undoManager = undoManager
        readUndoState(nil)
    }

    /// Reads whether there is something to undo and redo, after `notification` from an undo manager:
    /// only the scene's own matters (other ones, a text field's, post the same notifications).
    private func readUndoState(_ notification: Notification?) {
        if let notification, (notification.object as? UndoManager) !== undoManager { return }
        canUndo = undoManager?.canUndo ?? false
        canRedo = undoManager?.canRedo ?? false
    }

    /// Whether the document is waiting for its password.
    private var isLocked: Bool {
        if case .locked = model.state { true } else { false }
    }

    /// Whether the password prompt is up: while the document is locked and the reader has not put the
    /// prompt away.
    private var showsPasswordPrompt: Binding<Bool> {
        Binding(
            get: { isLocked && promptIsUp },
            set: { isShown in promptIsUp = isShown }
        )
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

    /// Whether the alert about a change that was not made is up: while the model has one to show.
    private var showsEditFailure: Binding<Bool> {
        Binding(
            get: { model.failure != nil },
            set: { isShown in if !isShown { model.failure = nil } }
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
                           selection: model.selection?.pageRects,
                           lastChange: model.lastChange)
                .ignoresSafeArea()
                // An overlay, not a bar: the scroll view's insets do not change when it appears.
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        searchHitBar
                        pageIndicator
                    }
                }
                // Each button is a Label, title and icon: the bar shows the icon, and when the bar has no
                // room for them all (a long file name beside the title menu, a narrow phone, large text)
                // iOS moves them into its "More" menu, which shows the titles. With icons alone (Image
                // and an accessibility label) the items in that menu were blank, so the menu looked
                // empty (reported on an iPhone, reproduced on the iOS 26.5 simulator).
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        undoButton
                        redoButton
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        copyButton
                        searchButton
                        thumbnailsButton
                    }
                }
                .sheet(item: $thumbnailsSheet) { presentation in
                    ThumbnailsSheet(model: model, store: presentation.store, scrollTarget: $scrollTarget)
                }
                // A change to the document makes every picture the store has drawn out of date (and its
                // pages, too): the store moves on to the new revision, and an open sheet with it.
                .onChange(of: model.revision) {
                    thumbnails?.reload(pages: model.pages, revision: model.revision)
                }
                // A change that was not made says why. No actions: the system gives the alert its OK.
                .alert(model.failure?.title ?? "", isPresented: showsEditFailure, presenting: model.failure) { _ in
                } message: { failure in
                    if !failure.message.isEmpty { Text(failure.message) }
                }
                .sheet(isPresented: $showsSearch) {
                    if let search = model.search {
                        SearchSheet(search: search, scrollTarget: $scrollTarget, revealRect: $revealRect)
                    }
                }
        case .locked:
            lockedScreen
        case .failed:
            failedScreen
        }
    }

    /// What a locked document shows, under its password prompt and once the prompt is put away: a
    /// lock, what the prompt says, and a button that brings the prompt back.
    private var lockedScreen: some View {
        ContentUnavailableView {
            Label(Strings.passwordTitle, systemImage: "lock.fill")
        } description: {
            Text(Strings.passwordExplanation)
        } actions: {
            Button(Strings.enterPassword) { promptIsUp = true }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("enterPasswordButton")
        }
    }

    /// What a document that could not be opened shows: nothing under the alert that says so, and the
    /// alert's words once it is answered, for when its Close button could not close the document.
    @ViewBuilder private var failedScreen: some View {
        if failureAnswered {
            ContentUnavailableView {
                Label(Strings.fileCouldNotBeOpened, systemImage: "exclamationmark.triangle")
            } description: {
                if let detail = failureDetail { Text(detail) }
            }
        } else {
            Color(.systemBackground)
                .ignoresSafeArea()
        }
    }

    /// The page the reader is on and how many there are, over the bottom of the pages. Not shown
    /// for a document with no pages.
    @ViewBuilder private var pageIndicator: some View {
        if model.pageCount > 0 {
            // While a change is being made a small spinner sits beside the numbers; nothing is held
            // back meanwhile (the model makes changes in the order they are tapped).
            HStack(spacing: 6) {
                if showsProgress {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityIdentifier("editProgress")
                }
                Text(Strings.pageIndicator(current: model.currentPage + 1, count: model.pageCount))
                    .accessibilityIdentifier("pageIndicator")
            }
            .font(.footnote.monospacedDigit())
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 8)
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
                Label(Strings.copy, systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("copyButton")
        }
    }

    /// Takes back the last change. Changes stay tappable while one is being made: the model makes
    /// them in order.
    private var undoButton: some View {
        Button {
            model.undo()
        } label: {
            Label(Strings.undo, systemImage: "arrow.uturn.backward")
        }
        .disabled(!canUndo)
        .accessibilityIdentifier("undoButton")
    }

    /// Makes again the change last taken back.
    private var redoButton: some View {
        Button {
            model.redo()
        } label: {
            Label(Strings.redo, systemImage: "arrow.uturn.forward")
        }
        .disabled(!canRedo)
        .accessibilityIdentifier("redoButton")
    }

    private var searchButton: some View {
        Button {
            showsSearch = true
        } label: {
            Label(Strings.search, systemImage: "magnifyingglass")
        }
        .disabled(model.pageCount == 0)
        .accessibilityIdentifier("searchButton")
    }

    private var thumbnailsButton: some View {
        Button(action: showThumbnails) {
            Label(Strings.thumbnails, systemImage: "square.grid.2x2")
        }
        .disabled(model.pageCount == 0)
        .accessibilityIdentifier("thumbnailsButton")
    }

    private func showThumbnails() {
        // Not while the sheet is already on its way up (a second tap), or a second one would replace it.
        guard thumbnailsSheet == nil, let document = model.document() else { return }
        // A store drawn for another screen resolution (the window moved to another display) is
        // replaced, so the pictures are sharp on this one.
        let kept = thumbnails.flatMap { $0.displayScale == displayScale ? $0 : nil }
        let store = kept ?? ThumbnailStore(document: document, pages: model.pages, revision: model.revision,
                                             displayScale: displayScale)
        thumbnails = store
        // The pictures the sheet opens on are drawn while it slides up, so its first rows are not
        // blank; the cells ask for the rest as they come into view.
        store.prefetch(around: model.currentPage, radius: ThumbnailsSheet.openingRadius)
        thumbnailsSheet = ThumbnailsPresentation(store: store)
    }
}
