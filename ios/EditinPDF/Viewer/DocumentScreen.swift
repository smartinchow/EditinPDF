import SwiftUI
import os

/// The screen for one document: its pages, once it is open, with the toolbar's buttons
/// (`toolbarItems`) and the page indicator (and, while a search has hits, the bar to move between
/// them) over the pages. In Markup mode the tool palette stands over the pages too: above the page
/// indicator on a compact width, at the leading edge on a regular one. The pages and the thumbnails
/// follow every change, undo and redo.
///
/// In reading mode a form's fields are filled in on the pages (`FormInteraction`). When the document
/// has a form that may be filled in, a hint says so once (`Strings.formHint`), with a note when the
/// form is larger than is listed (`Strings.formTruncated`); a list box of several choices opens its
/// options in a sheet (`ChoiceSheet`).
///
/// A document that is locked has no pages to show yet: the prompt for its password (`PasswordSheet`)
/// comes up over a screen that says it is locked. Cancel puts the prompt away and leaves that screen,
/// whose Enter Password button brings the prompt back. One that could not be read has an alert saying
/// so, and once the alert is answered the screen says the same, for as long as it is still there.
///
/// Neither relies on closing the document from inside it, which `dismiss` does on iOS 26 but is
/// reported not to do on iOS 17 and 18: with the prompt or the alert put away, the system's own way
/// back to the documents, in the navigation bar, is always there.
///
/// Saving is the reader's choice (ADR 0002, section 3): nothing is written to the file but by Save, in
/// the More menu and as ⌘S (`save`). "Edited" under the document's name says there is something to
/// save. Back, with unsaved changes, asks whether to Save, Save As or Discard them, or to stay
/// (`goBack`). While there are unsaved changes, a recovery copy keeps them (`RecoveryStore`), written a
/// moment after each change and as the scene leaves the screen, and offered when the document opens
/// again after the app was stopped without a choice made (`offerRecoveredChanges`).
struct DocumentScreen: View {
    let model: DocumentModel
    /// The document's file name, without its extension, for the name of pages extracted from it, and
    /// for the question Back asks.
    var documentName = Strings.untitledDocument
    /// The document's file: the key of its recovery copy, and when it last changed. Nil for none.
    var fileURL: URL?
    /// A page to jump to, for the thumbnails and search to set.
    @State private var scrollTarget: Int?
    /// A box to bring into view on that page, for search to set along with it.
    @State private var revealRect: PageRect?
    /// Whether the search sheet is up. The search itself is the model's, so it is the same one each
    /// time the sheet opens.
    @State private var showsSearch = false
    /// Whether the Comments list is up.
    @State private var showsComments = false
    /// Set to show the thumbnails sheet, and cleared when it closes.
    @State private var thumbnailsSheet: ThumbnailsPresentation?
    /// Set to show Organize Pages, and cleared when it closes.
    @State private var organizeCover: ThumbnailsPresentation?
    /// Made when the thumbnails are first asked for and kept while the document is on screen, so the
    /// sheet opens with its pictures the next time. Organize Pages shows the same pictures.
    @State private var thumbnails: ThumbnailStore?
    @Environment(\.displayScale) private var displayScale
    /// The width class of the scene, which places the tool palette (`PaletteLayout`): read again
    /// whenever the width changes (an iPhone Duo folding or unfolding, Split View on a tablet).
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// Whether the scene is on screen and active: strokes drawn with Draw are added as it leaves.
    @Environment(\.scenePhase) private var scenePhase
    /// The scene's undo manager: the model registers its changes with it only for a document saved the
    /// system's way (`SavingMode.automatic`); otherwise the model keeps its own.
    @Environment(\.undoManager) private var sceneUndoManager
    /// Whether Undo and Redo may be tapped now, here and in the Edit menu (`DocumentModel.undoAvailability`).
    private var undoAvailability: UndoAvailability { model.undoAvailability }
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
    /// Whether the hint about the form (`Strings.formHint`) has been shown since the document opened:
    /// it is shown once.
    @State private var formHintShown = false
    /// Whether the hint about the form is up.
    @State private var showsFormHint = false
    /// Whether Save As is making its copy, until the exporter is up or it failed: a second tap
    /// meanwhile does nothing.
    @State private var makingCopy = false
    /// The view whose window Save As's exporter is presented from.
    @State private var anchor = PresentationAnchor.Holder()
    /// Why Save As made or wrote no copy, while the alert that says so is up.
    @State private var copyFailure: CopyFailure?
    /// Set by Send Feedback; the feedback sender acts on it and clears it (`feedbackSender`).
    @State private var feedbackRequested = false
    /// The view controller the scene shows the document in: its back button and its document
    /// (`DocumentHost`).
    @State private var host = DocumentHost()
    /// Whether Back is adding what waits and looking for unsaved changes: a second tap meanwhile does
    /// nothing.
    @State private var goingBack = false
    /// Whether the question Back asks with unsaved changes is up.
    @State private var showsSaveQuestion = false
    /// Why Save wrote nothing, while the alert that says so is up.
    @State private var saveFailure: SaveFailure?
    /// What the changes kept from before (the recovery copy) are, while the offer of them is up. Put away
    /// unanswered (the Cancel the system adds), the copy is kept (`DocumentModel.recoveryHeld`), offered
    /// again the next time the document opens.
    @State private var recoveryOffer: RecoveredCopyKind?
    /// Whether the recovery copy has been looked for since the document opened: once.
    @State private var recoveryLookedFor = false
    /// Whether the alert saying the kept changes could not be restored is up.
    @State private var showsRestoreFailure = false
    /// Set once the screen has gone: a close that left it on screen is undone (`close`).
    @State private var hasGone = false

    private static let log = Logger(subsystem: Diagnostics.subsystem, category: "copy")

    /// What the thumbnails sheet (and Organize Pages) is shown with. The store travels in the item the sheet is presented
    /// for, instead of the sheet's content reading it from this view's state: done that way the
    /// content ran with the store still nil, though the button's action had set it just before
    /// (observed on the iOS 26.5 simulator, in a document scene).
    private struct ThumbnailsPresentation: Identifiable {
        let id = UUID()
        let store: ThumbnailStore
    }

    var body: some View {
        content
            .onAppear { appear() }
            // Strokes drawn with Draw and waiting are added as the screen goes. (Back adds them before it
            // asks: `goBack`.) Unsaved changes the reader made no choice about (the system's own back
            // action, where it could not be taken over) are kept in the recovery copy.
            .onDisappear {
                hasGone = true
                model.commitPendingInk(closing: true)
                FrontDocument.shared.leave(model)
                if model.needsSave, !model.isClosing {
                    BackgroundWork.run { await model.writeRecovery(addingWhatWaits: true) }
                }
            }
            // Strokes left waiting on the page are added before the scene leaves the screen, and the
            // recovery copy is written with them: the app may be stopped in the background, or its
            // scene closed from the app switcher, with no word to the app.
            .onChange(of: scenePhase) {
                if scenePhase != .active { model.commitPendingInk(closing: true) }
                // A note being written is saved, and the recovery copy written with it, as the scene goes
                // to the background: the app may not come back to it. Only inactive (the app switcher, a
                // notification pulled down), the note sheet stays as it is.
                if scenePhase == .background {
                    model.saveNoteDraftOnLeaving()
                    if model.needsSave { BackgroundWork.run { await model.writeRecovery(addingWhatWaits: true) } }
                } else if scenePhase == .inactive, model.needsSave {
                    BackgroundWork.run { await model.writeRecovery() }
                }
            }
            // After a few seconds without a change, undo or redo, the recovery copy is written with them
            // (not after each: the write holds the document while it runs, a while on a big one).
            .task(id: model.historyPosition) {
                try? await Task.sleep(for: .seconds(5))
                if !Task.isCancelled { await model.writeRecovery() }
            }
            // Once the document is open (a locked one, once unlocked): changes kept from before are offered.
            .task(id: isOpen) { await offerRecoveredChanges() }
            .modifier(EditedSubtitle(edited: model.needsSave))
            .background(DocumentHostAnchor(host: host, needsSave: model.needsSave, toolbarState: toolbarState))
            .alert(Strings.saveChangesTitle(documentName), isPresented: $showsSaveQuestion) {
                // The system alert does not pass identifiers on to its buttons (see the alert below): the
                // UI tests find them by their titles. Save is the default (Return).
                Button(Strings.saveDocument) { saveThenClose() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("saveQuestionSave")
                Button(Strings.saveAs) { saveCopy(closingOnceSaved: true) }
                    .accessibilityIdentifier("saveQuestionSaveAs")
                Button(Strings.discardChanges, role: .destructive) {
                    model.discardChanges()
                    close()
                }
                .accessibilityIdentifier("saveQuestionDiscard")
                Button(Strings.cancel, role: .cancel) {}
                    .accessibilityIdentifier("saveQuestionCancel")
            } message: {
                Text(Strings.saveChangesMessage)
            }
            .alert(Strings.saveFailedTitle, isPresented: showsSaveFailure, presenting: saveFailure) { _ in
            } message: { failure in
                Text(failure.message)
            }
            .alert(Strings.restoreTitle, isPresented: showsRecoveryOffer(.restorable)) {
                Button(Strings.restore) {
                    Task {
                        if await !model.restoreRecoveredChanges() { showsRestoreFailure = true }
                        await offerNextRecoveredChanges()
                    }
                }
                .accessibilityIdentifier("restoreRecoveredButton")
                Button(Strings.discardRecovered, role: .destructive) {
                    model.discardRecoveredChanges()
                    Task { await offerNextRecoveredChanges() }
                }
                .accessibilityIdentifier("discardRecoveredButton")
            } message: {
                Text(Strings.restoreMessage(documentName))
            }
            .alert(Strings.earlierVersionTitle, isPresented: showsRecoveryOffer(.earlierVersion)) {
                Button(Strings.saveAs) { exportRecoveredCopy() }
                    .accessibilityIdentifier("exportRecoveredButton")
                Button(Strings.discardRecovered, role: .destructive) {
                    model.discardRecoveredChanges()
                    Task { await offerNextRecoveredChanges() }
                }
                .accessibilityIdentifier("discardRecoveredButton")
            } message: {
                Text(Strings.earlierVersionMessage(documentName))
            }
            .alert(Strings.restoreFailedTitle, isPresented: $showsRestoreFailure) {
            } message: {
                Text(Strings.restoreFailedMessage)
            }
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

    /// As the screen appears: shows what can be undone and redone, names the recovery copy after the
    /// file, and wires ⌘S and the back button to this screen.
    private func appear() {
        readUndoState(nil)
        model.recoveryKey = fileURL.map(RecoveryStore.key(for:))
        model.saveRequested = { save() }
        model.closeRequested = { goBack() }
        host.goBack = { goBack() }
        let undoManager = sceneUndoManager
        host.onDecided = { mode in
            model.adopt(mode, sceneUndoManager: undoManager)
            readUndoState(nil)
        }
    }

    /// What the toolbar shows, for the host to look at the navigation item again as it changes
    /// (`DocumentHostAnchor.toolbarState`).
    private var toolbarState: String {
        "\(model.selection?.selection != nil)|\(String(describing: model.tool))|\(String(describing: horizontalSizeClass))"
    }

    /// Whether the offer of changes kept from before, of `kind`, is up.
    private func showsRecoveryOffer(_ kind: RecoveredCopyKind) -> Binding<Bool> {
        Binding(get: { recoveryOffer == kind }, set: { isShown in if !isShown { recoveryOffer = nil } })
    }

    /// Reads whether there is something to undo and redo, and its name, after `notification` from an
    /// undo manager: only the model's own matters (other ones, a text field's, post the same
    /// notifications). The undo manager is not observable, so the model is told (`undoStackDidChange`).
    private func readUndoState(_ notification: Notification?) {
        let undoManager = model.undoManager
        if let notification, (notification.object as? UndoManager) !== undoManager { return }
        model.undoStackDidChange(canUndo: undoManager?.canUndo ?? false, canRedo: undoManager?.canRedo ?? false,
                                 undoName: undoManager?.undoActionName ?? "", redoName: undoManager?.redoActionName ?? "")
    }

    /// Whether the document is open.
    private var isOpen: Bool {
        if case .open = model.state { true } else { false }
    }

    /// Whether the alert about a save that wrote nothing is up: once no alert about a change refused is.
    private var showsSaveFailure: Binding<Bool> {
        Binding(get: { saveFailure != nil && model.failure == nil }, set: { isShown in if !isShown { saveFailure = nil } })
    }

    // MARK: Saving and going back

    /// Save: writes the changes to the file (`DocumentModel.save`), and says so when it could not.
    private func save() {
        model.fileWriter = host.writer
        Task {
            if let failure = await model.save() {
                saveFailure = failure
                return
            }
            #if DEBUG
            // For a UI test: the scene's document made to look edited after Save, so that it saves as it
            // closes, as the system would on its own (`FixtureStaging.dirtyAfterSaveArgument`).
            if ProcessInfo.processInfo.arguments.contains(FixtureStaging.dirtyAfterSaveArgument) {
                host.controller?.document?.updateChangeCount(.done)
            }
            #endif
        }
    }

    /// The back button: adds what waits (strokes, text being typed), then closes the document when it has
    /// nothing to save, or asks whether to Save, Save As or Discard the changes, or to stay.
    private func goBack() {
        guard !goingBack else { return }
        goingBack = true
        Task {
            defer { goingBack = false }
            model.commitPendingInk(closing: true)
            await model.settle()
            if model.needsSave {
                showsSaveQuestion = true
            } else {
                close()
            }
        }
    }

    /// The question's Save: closes once the file is written; stays, saying why, when it could not be.
    private func saveThenClose() {
        model.fileWriter = host.writer
        Task {
            if let failure = await model.save() {
                saveFailure = failure
            } else {
                close()
            }
        }
    }

    /// Back to the documents, with nothing written: the scene's document has no change to save of its
    /// own (ADR 0002, section 3). This session's recovery copy goes when nothing is unsaved (changes undone
    /// back to the file); copies kept from before stay. Through the system's back action
    /// (`DocumentHost.close`), or `dismiss` where there is none or it left the document on screen; the
    /// reader is never left with a document that will not close and no recovery copy.
    private func close() {
        if !model.needsSave { model.deleteRecovery() }
        model.isClosing = true
        if !host.close() { closeDocument() }
        // Still on screen a moment later (no way to close was found): the document is not closing after
        // all, and its changes are kept in the recovery copy again.
        Task {
            try? await Task.sleep(for: .seconds(3))
            guard !hasGone, host.isStillShowingTheDocument else { return }
            // The system's back action did nothing: SwiftUI's own way to close the document, and only
            // when that leaves it on screen too, it stays open, its changes kept in the recovery copy.
            closeDocument()
            try? await Task.sleep(for: .seconds(3))
            guard !hasGone, host.isStillShowingTheDocument else { return }
            model.isClosing = false
            await model.writeRecovery()
        }
    }

    /// Looks, once the document is open, for changes kept from a time the app was stopped before they
    /// were saved, and offers them: to restore, when they were made on top of the file as it is; to save
    /// as a copy or discard, when the file has changed since (`RecoveredCopyKind`). Never dropped without
    /// the reader's word.
    private func offerRecoveredChanges() async {
        guard isOpen, !recoveryLookedFor else { return }
        recoveryLookedFor = true
        await offerNextRecoveredChanges()
    }

    /// Offers the next copy kept from before, once one is answered (there can be two: one put away
    /// unanswered, and the copy of the session after it, kept beside it).
    private func offerNextRecoveredChanges() async {
        // The alert just answered goes first, or the next would not come up.
        try? await Task.sleep(for: .milliseconds(400))
        recoveryOffer = await model.findRecoveredChanges(fileURL: fileURL)
    }

    /// Save As for changes kept from an earlier version of the file: the kept copy, as it is, through the
    /// system's exporter, under the document's name and " copy". Once it is saved, the kept copy goes;
    /// cancelled, it stays, offered again the next time.
    private func exportRecoveredCopy() {
        let name = Strings.copyName(of: documentName)
        Task {
            guard let bytes = await model.recoveredCopyBytes() else {
                copyFailure = .failed
                return
            }
            let written = await EditQueue.offMain { try CopyFiles.write(bytes, named: name) }
            guard case .success(let file) = written, let presenter = anchor.topViewController else {
                if case .success(let file) = written { CopyFiles.remove(file) }
                copyFailure = .failed
                return
            }
            CopyExporter.present(file, over: presenter) { saved in
                guard saved else { return }
                model.discardRecoveredChanges()
                Task { await offerNextRecoveredChanges() }
            }
        }
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

    /// The note the note sheet is up for, while it is. While the Comments list is up, the list shows the
    /// sheet over itself.
    private var noteDraft: Binding<NoteDraft?> {
        Binding(get: { showsComments ? nil : model.noteDraft }, set: { model.noteDraft = $0 })
    }

    /// Why a change was not made, for the note sheet to show over itself while it is up.
    private var editFailure: Binding<EditFailure?> {
        Binding(get: { model.failure }, set: { model.failure = $0 })
    }

    /// The text box the format sheet is up for, while it is.
    private var formatDraft: Binding<TextBoxFormatDraft?> {
        Binding(get: { model.formatDraft }, set: { model.formatDraft = $0 })
    }

    /// The list box the sheet of options is up for, while it is.
    private var choiceDraft: Binding<ChoiceDraft?> {
        Binding(get: { model.choiceDraft }, set: { model.choiceDraft = $0 })
    }

    /// Whether the signature pad is up.
    private var showsSignaturePad: Binding<Bool> {
        Binding(get: { model.showsSignaturePad }, set: { model.showsSignaturePad = $0 })
    }

    /// Whether the alert about a change that was not made is up: while the model has one to show, and
    /// neither the note sheet, the signature pad nor the Comments list, which show their own, nor the
    /// sheet of a list's options, is up.
    private var showsEditFailure: Binding<Bool> {
        Binding(
            get: { model.failure != nil && model.noteDraft == nil && !model.showsSignaturePad && !showsComments && model.choiceDraft == nil },
            set: { isShown in if !isShown { model.failure = nil } }
        )
    }

    /// Whether the alert about a copy that was not saved is up: once no alert about a change refused is.
    private var showsCopyFailure: Binding<Bool> {
        Binding(get: { copyFailure != nil && model.failure == nil }, set: { isShown in if !isShown { copyFailure = nil } })
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
                           lastChange: model.lastChange,
                           tool: model.tool,
                           selectedAnnotation: model.selectedAnnotationPlace,
                           forms: FormDisplay(index: model.formIndex, canFill: model.canFillForms))
                // A document restored from its recovery copy is another engine document: its pages are
                // made again for it.
                .id(model.documentGeneration)
                .ignoresSafeArea()
                // An overlay, not a bar: the scroll view's insets do not change when it appears.
                .overlay(alignment: .bottom) {
                    VStack(spacing: 8) {
                        searchHitBar
                        if model.tool != nil, paletteLayout == .bottomBar {
                            ToolPalette(model: model, layout: .bottomBar)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        pageIndicator
                    }
                }
                // On a regular width the tools stand in a column at the leading edge; the navigation
                // bar's own column, on an iPhone Duo, stands at the trailing one.
                .overlay(alignment: .leading) {
                    if model.tool != nil, paletteLayout == .sidePalette {
                        ToolPalette(model: model, layout: .sidePalette)
                            .transition(.move(edge: .leading).combined(with: .opacity))
                    }
                }
                // Once, when a document with a form that may be filled in opens, in reading mode: how to
                // fill it in, and that it is too large to show in full when it has more than are listed.
                .overlay(alignment: .top) {
                    if showsFormHint, model.tool == nil {
                        formHint
                            .transition(.move(edge: .top).combined(with: .opacity))
                    } else if model.showsAddCommentHint {
                        addCommentHint
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: model.showsAddCommentHint)
                .task(id: hasFormToFill) { await showFormHintOnce() }
                .animation(.snappy, value: showsFormHint)
                .animation(.snappy, value: model.tool == nil)
                .animation(.snappy, value: paletteLayout)
                .toolbar { toolbarItems }
                .sheet(item: $thumbnailsSheet) { presentation in
                    ThumbnailsSheet(model: model, store: presentation.store, scrollTarget: $scrollTarget)
                }
                .fullScreenCover(item: $organizeCover) { presentation in
                    OrganizeScreen(model: model, store: presentation.store, documentName: documentName)
                }
                // A change to the document makes every picture the store has drawn out of date (and its
                // pages, too): the store moves on to the new revision, and an open sheet with it.
                .onChange(of: model.revision) {
                    thumbnails?.reload(pages: model.pages, revision: model.revision)
                }
                // The pictures drawn of a document replaced by its recovery copy are of the other one.
                .onChange(of: model.documentGeneration) { thumbnails = nil }
                // A change that was not made says why. No actions: the system gives the alert its OK.
                .alert(model.failure?.title ?? "", isPresented: showsEditFailure, presenting: model.failure) { _ in
                } message: { failure in
                    if !failure.message.isEmpty { Text(failure.message) }
                }
                // Save As's exporter is presented from this view's window (`saveCopy`). Success needs no
                // word of ours (the exporter going is enough); a failure says so, after the alert about a
                // change refused, when there is one.
                .background(PresentationAnchor(holder: anchor))
                .alert(Strings.copyFailedTitle, isPresented: showsCopyFailure, presenting: copyFailure) { _ in
                } message: { failure in
                    Text(failure.message)
                }
                // Send Feedback: Mail's composer, prefilled with the app's version and the device, and
                // nothing of the document; or a mailto: link; or the address to copy.
                .feedbackSender(isRequested: $feedbackRequested)
                .sheet(isPresented: $showsSearch) {
                    if let search = model.search {
                        SearchSheet(search: search, scrollTarget: $scrollTarget, revealRect: $revealRect)
                    }
                }
                // The comments, page by page: a tap jumps to one and selects it, a swipe deletes it.
                .sheet(isPresented: $showsComments) {
                    CommentsSheet(model: model, failure: editFailure, jump: { row in jump(to: row) }, addComment: {
                        showsComments = false
                        model.startAddingComment()
                    })
                }
                // A tap on a list box of several choices opens its options here: Done fills it with those
                // checked, Cancel leaves it as it was.
                .sheet(item: choiceDraft) { draft in
                    ChoiceSheet(draft: draft, save: { values in
                        await model.saveChoice(draft, choosing: values)
                    }, cancel: {
                        model.choiceDraft = nil
                    })
                }
                // A tap with Note opens its note here: Save adds or changes it, and the sheet goes once it
                // has; a refusal says why over the sheet, which stays with what was written. Cancel leaves
                // the note as it was.
                .sheet(item: noteDraft) { draft in
                    NoteEditorSheet(draft: draft, failure: editFailure, save: { text in
                        await model.saveNoteDraft(text: text)
                    }, cancel: {
                        model.noteDraft = nil
                    }, written: { text in
                        model.noteTextDidChange(text)
                    })
                }
                // Select's Format over a text box opens its look here: Apply gives it the look picked, one
                // change; Cancel leaves it as it was.
                .sheet(item: formatDraft) { draft in
                    TextBoxFormatSheet(draft: draft, apply: { format in
                        Task { await model.applyFormatDraft(format) }
                    }, cancel: {
                        model.formatDraft = nil
                    })
                }
                // Sign picked or tapped with no signature saved, or Change Signature, opens the pad here:
                // Save keeps what is drawn (the pad goes once it is kept), Cancel leaves the saved one.
                .sheet(isPresented: showsSignaturePad) {
                    SignaturePadSheet(failure: editFailure, save: { signature in
                        model.saveSignature(signature)
                    }, cancel: {
                        model.showsSignaturePad = false
                    })
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

    /// Whether the document has a form that may be filled in: the hint about it is shown once then.
    private var hasFormToFill: Bool {
        !model.formIndex.isEmpty && model.canFillForms
    }

    /// Shows the hint about the form for a few seconds, the first time the document has a form that may
    /// be filled in.
    private func showFormHintOnce() async {
        guard hasFormToFill, !formHintShown else { return }
        formHintShown = true
        showsFormHint = true
        try? await Task.sleep(for: .seconds(6))
        showsFormHint = false
    }

    /// The hint about the form, and the note about a form larger than is listed; a tap puts it away.
    private var formHint: some View {
        VStack(spacing: 2) {
            Text(Strings.formHint)
                .accessibilityIdentifier("formHint")
            if model.formFieldsTruncated {
                Text(Strings.formTruncated)
                    .accessibilityIdentifier("formTruncatedNote")
            }
        }
        .font(.footnote)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 8)
        .padding(.horizontal, 16)
        .onTapGesture { showsFormHint = false }
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
                // Before iOS 26 the navigation bar has no line under the name (`DocumentHost.showEdited`): it
                // is said here.
                if #unavailable(iOS 26), model.needsSave {
                    Text(Strings.edited)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("editedIndicator")
                }
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

    /// The toolbar's buttons. Each is a Label, title and icon: the bar shows the icon, and when the bar
    /// has no room for them all (a long file name beside the title menu, a narrow phone, large text)
    /// iOS moves them into its "More" menu, which shows the titles. With icons alone (Image and an
    /// accessibility label) the items in that menu were blank, so the menu looked empty (reported on an
    /// iPhone, reproduced on the iOS 26.5 simulator).
    ///
    /// Undo and Redo lead the trailing group, at every width. Alone at the leading end they went
    /// missing after an edit and a scroll that brought the bar's background in and out: reported on an
    /// iPhone, and seen on the iOS 26.5 simulator on an iPad Pro 11, with room to spare (not on the
    /// iPhone simulator). iOS can also move trailing items into its More menu, and not leading ones.
    /// On a compact width the bar is short of room: Comments, Thumbnails and Organize Pages are in the
    /// bar's own menu of further actions there, listed with their titles. On a regular one all are shown.
    /// Save, Save As and Send Feedback are in that menu at every width.
    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
        if horizontalSizeClass == .compact {
            ToolbarItemGroup(placement: .primaryAction) {
                undoButton
                redoButton
                copyButton
                markupButton
                searchButton
            }
            ToolbarItemGroup(placement: .secondaryAction) {
                if model.savingMode != .automatic { saveButton }
                commentsButton
                thumbnailsButton
                organizeButton
                saveCopyButton
                feedbackButton
            }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) {
                undoButton
                redoButton
                copyButton
                markupButton
                searchButton
                commentsButton
                thumbnailsButton
                organizeButton
            }
            // The bar's More menu, as on a compact width.
            ToolbarItemGroup(placement: .secondaryAction) {
                if model.savingMode != .automatic { saveButton }
                saveCopyButton
                feedbackButton
            }
        }
    }

    /// Where the tool palette stands for the scene's width.
    private var paletteLayout: PaletteLayout { PaletteLayout.for(horizontalSizeClass) }

    /// Turns Markup mode on (with the Select tool) and off (back to reading, where touches scroll,
    /// zoom and select text).
    private var markupButton: some View {
        Button {
            model.tool = model.tool == nil ? .select : nil
        } label: {
            Label(Strings.markup, systemImage: model.tool == nil ? "pencil.tip.crop.circle" : "pencil.tip.crop.circle.fill")
        }
        .disabled(model.pageCount == 0)
        .accessibilityIdentifier("markupButton")
        .accessibilityAddTraits(model.tool == nil ? [] : .isSelected)
    }

    /// Takes back the last change. Changes stay tappable while one is being made: the model makes
    /// them in order. Strokes drawn with Draw, or text typed in a text box or a form field, waiting
    /// count as a change: Undo adds them, then takes them back (`UndoAvailability`). ⌘Z is the Edit
    /// menu's (`UndoRedoCommands`), which does the same.
    private var undoButton: some View {
        Button {
            model.undo()
        } label: {
            Label(Strings.undo, systemImage: "arrow.uturn.backward")
        }
        .disabled(!undoAvailability.undoEnabled)
        .accessibilityIdentifier("undoButton")
    }

    /// Makes again the change last taken back. Not while strokes drawn with Draw, or text typed in a
    /// text box or a form field, are waiting: they are a change after it, and adding them leaves
    /// nothing to redo. ⇧⌘Z is the Edit menu's, under the same rule.
    private var redoButton: some View {
        Button {
            model.redo()
        } label: {
            Label(Strings.redo, systemImage: "arrow.uturn.forward")
        }
        .disabled(!undoAvailability.redoEnabled)
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

    /// Opens the list of the document's comments and markup.
    private var commentsButton: some View {
        Button {
            showsComments = true
        } label: {
            Label(Strings.comments, systemImage: "text.bubble")
        }
        .disabled(model.pageCount == 0)
        .accessibilityIdentifier("commentsButton")
    }

    /// After Add Comment, until the comment is placed: where it goes. It only says something: a tap on
    /// it goes through to the page under it.
    private var addCommentHint: some View {
        Label(Strings.addCommentHint, systemImage: "hand.tap")
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .allowsHitTesting(false)
            .accessibilityIdentifier("addCommentHint")
    }

    /// What Show on Page beside a row of the Comments list does: the list goes, Markup's Select is picked, and the
    /// annotation is selected and brought into view (its page to the top, then its box into view).
    private func jump(to row: CommentRow) {
        showsComments = false
        if model.tool != .select { model.tool = .select }
        model.selectedAnnotation = row.id
        scrollTarget = row.page
        revealRect = PageRect(page: row.page, rect: row.rect)
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
        guard thumbnailsSheet == nil, let store = thumbnailStore() else { return }
        // The pictures the sheet opens on are drawn while it slides up, so its first rows are not
        // blank; the cells ask for the rest as they come into view.
        store.prefetch(around: model.currentPage, radius: ThumbnailsSheet.openingRadius)
        thumbnailsSheet = ThumbnailsPresentation(store: store)
    }

    /// Opens, over everything, the grid where pages are selected, moved, turned, deleted and added.
    private var organizeButton: some View {
        Button(action: showOrganize) {
            Label(Strings.organize, systemImage: "rectangle.grid.2x2")
        }
        .disabled(model.pageCount == 0)
        .accessibilityIdentifier("organizeButton")
    }

    private func showOrganize() {
        guard organizeCover == nil, let store = thumbnailStore() else { return }
        organizeCover = ThumbnailsPresentation(store: store)
    }

    /// Writes the changes to the document's file (`save`); ⌘S does the same (`SaveCommands`). Only while
    /// there is something to save.
    private var saveButton: some View {
        Button(action: save) {
            Label(Strings.saveDocument, systemImage: "square.and.arrow.down")
        }
        .disabled(!model.needsSave || model.isSaving)
        .accessibilityIdentifier("saveButton")
    }

    /// Saves a copy of the document, with its changes, where the reader chooses (`saveCopy`).
    private var saveCopyButton: some View {
        Button { saveCopy() } label: {
            Label(Strings.saveAs, systemImage: "square.and.arrow.down.on.square")
        }
        .disabled(model.pageCount == 0 || makingCopy)
        .accessibilityIdentifier("saveCopyButton")
    }

    /// Writes an email of feedback to the app's makers (`feedbackSender`).
    private var feedbackButton: some View {
        Button {
            feedbackRequested = true
        } label: {
            Label(Strings.sendFeedback, systemImage: "envelope")
        }
        .accessibilityIdentifier("sendFeedbackButton")
    }

    /// Makes the copy's bytes (`DocumentModel.copyBytes`: what waits is added first, and the changes on
    /// their way are waited for), writes them in a folder of the app's own (`CopyFiles`), off the main
    /// actor, and puts up the system's exporter for the file (`CopyExporter`), named as the document and
    /// " copy". The folder goes once the exporter is done, saved or cancelled. A copy that cannot be made
    /// says why, and no exporter comes up. Nothing stays set that would hold back the next tap: the
    /// exporter is modal while it is up. As the question Back asks's Save As (`closingOnceSaved`), the
    /// document closes once the copy is saved, its file as it was; cancelled, it stays open.
    private func saveCopy(closingOnceSaved: Bool = false) {
        guard !makingCopy else { return }
        makingCopy = true
        let name = Strings.copyName(of: documentName)
        Task {
            defer { makingCopy = false }
            let bytes: Data
            switch await model.copyBytes() {
            case .success(let made): bytes = made
            case .failure(let failure):
                copyFailure = failure
                return
            }
            let written = await EditQueue.offMain { try CopyFiles.write(bytes, named: name) }
            switch written {
            case .success(let file):
                guard let presenter = anchor.topViewController else {
                    CopyFiles.remove(file)
                    copyFailure = .failed
                    return
                }
                CopyExporter.present(file, over: presenter) { saved in
                    guard closingOnceSaved, saved else { return }
                    model.copyWasSaved()
                    // The exporter is told the copy was saved before it has gone, and a document whose
                    // window still presents it does not close (the iPad's full-screen exporter): closed
                    // once it has gone, a few seconds at most.
                    Task {
                        for _ in 0..<60 where presenter.presentedViewController != nil {
                            try? await Task.sleep(for: .milliseconds(50))
                        }
                        close()
                    }
                }
            case .failure(let error):
                // Nothing of the document in the readable log.
                Self.log.error("writing a copy failed: \(String(describing: error), privacy: .private)")
                copyFailure = .failed
            }
        }
    }

    /// The store of page pictures, made the first time it is needed and kept: the same pictures for
    /// the thumbnails and Organize. Nil unless the document is open.
    private func thumbnailStore() -> ThumbnailStore? {
        guard let document = model.document() else { return nil }
        // A store drawn for another screen resolution (the window moved to another display) is
        // replaced, so the pictures are sharp on this one. A kept store is brought up to the
        // document's revision (it does nothing when it is there already).
        let kept = thumbnails.flatMap { $0.displayScale == displayScale ? $0 : nil }
        let store = kept ?? ThumbnailStore(document: document, pages: model.pages, revision: model.revision,
                                             displayScale: displayScale)
        store.reload(pages: model.pages, revision: model.revision)
        thumbnails = store
        return store
    }
}

/// Whether Undo and Redo may be chosen: the toolbar's buttons and the Edit menu's (and their keys)
/// follow the same rule. Undo, when the undo manager has a change to take back or something is
/// waiting to be added (it adds that, then takes it back); Redo, when the undo manager has a change to
/// make again and nothing is waiting (adding it would leave nothing to redo). The Edit menu names the
/// change each makes, under the same rule (`undoTitle`, `redoTitle`).
struct UndoAvailability: Equatable {
    var canUndo = false
    var canRedo = false
    /// Strokes, or text typed in a text box or a form field, waiting to be added
    /// (`DocumentModel.hasPendingEdit`).
    var hasPendingEdit = false
    /// The names of the changes the undo manager would take back and make again (empty for none), and
    /// of the change what waits makes (`DocumentModel.pendingEditName`).
    var undoName = ""
    var redoName = ""
    var pendingName: String?

    var undoEnabled: Bool { canUndo || hasPendingEdit }
    var redoEnabled: Bool { canRedo && !hasPendingEdit }

    /// The Edit menu's Undo: "Undo" and the change it takes back, as the system's menu has it. That is
    /// what waits, when something does (added, then taken back), or else the undo manager's last change.
    /// Plain "Undo" while it is off, or for a change with no name.
    var undoTitle: String {
        let name = hasPendingEdit ? pendingName ?? "" : undoName
        return undoEnabled && !name.isEmpty ? Strings.undoAction(name) : Strings.undo
    }

    /// The Edit menu's Redo: "Redo" and the change it makes again; plain "Redo" while it is off
    /// (nothing to redo, or something waiting).
    var redoTitle: String {
        redoEnabled && !redoName.isEmpty ? Strings.redoAction(redoName) : Strings.redo
    }
}

/// The document in front (its screen on display in the key window's scene): what the Edit menu's Undo
/// and Redo act on (`UndoRedoCommands`). SwiftUI's focused values do not reach the app's commands from
/// a document scene's view (the commands read none, on the iOS 26.5 simulator, iPhone and iPad), so
/// each screen says which scene it is shown in (`show`) and when it goes (`leave`), and the document
/// in front is found again from the key window (`front(of:keyScene:)`): as a window becomes key, and
/// as a command runs. Not from the scene that became active last: two side by side on an iPad are both
/// active, and only the key window takes the keyboard's commands; a key window showing the document
/// browser has no document in front.
///
/// While a field outside the pages is typed in (the search, a note, a password), Undo and Redo are
/// that field's, as in any field (`fieldIsBeingTyped`). The text box and form field editors on the
/// pages are not such fields: there Undo adds what was typed, then takes it back, as the toolbar's does.
@MainActor
@Observable
final class FrontDocument: NSObject {
    static let shared = FrontDocument()

    /// Whether a field outside the pages is being typed in.
    private(set) var fieldIsBeingTyped = false

    override init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(windowBecameKey(_:)), name: UIWindow.didBecomeKeyNotification, object: nil)
        for name in [UITextField.textDidBeginEditingNotification, UITextView.textDidBeginEditingNotification] {
            center.addObserver(self, selector: #selector(editingBegan(_:)), name: name, object: nil)
        }
        for name in [UITextField.textDidEndEditingNotification, UITextView.textDidEndEditingNotification] {
            center.addObserver(self, selector: #selector(editingEnded(_:)), name: name, object: nil)
        }
    }

    @objc private func editingBegan(_ notification: Notification) {
        if let field = notification.object as? UIView, !Self.isOnThePages(field) { fieldIsBeingTyped = true }
    }

    @objc private func editingEnded(_ notification: Notification) {
        if let field = notification.object as? UIView, !Self.isOnThePages(field) { fieldIsBeingTyped = false }
    }

    /// Whether `view` is in a page scroll view: a text box's or a form field's editor.
    static func isOnThePages(_ view: UIView) -> Bool {
        sequence(first: view, next: \.superview).contains { $0 is PagesScrollView }
    }

    /// The field being typed in outside the pages: the first responder, when it takes text and is in
    /// no page scroll view. Nil when there is none.
    static func fieldBeingTyped() -> UIResponder? {
        FirstResponder.found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.editinPDFReportFirstResponder), to: nil, from: nil, for: nil)
        guard let responder = FirstResponder.found, responder is UITextInput else { return nil }
        if let view = responder as? UIView, isOnThePages(view) { return nil }
        return responder
    }

    /// The Edit menu's Undo: the field's, while one outside the pages is typed in; otherwise the
    /// document's in front, found again as the command runs (`DocumentModel.undo`, which adds what
    /// waits first).
    func undo() {
        if let field = Self.fieldBeingTyped() {
            field.undoManager?.undo()
        } else {
            refresh()
            model?.undo()
        }
    }

    /// ⌘S: Save, for the document in front (`DocumentModel.saveRequested`).
    func save() {
        refresh()
        model?.saveRequested?()
    }

    /// ⌘W (the File menu's Close): Back, for the document in front (`DocumentModel.closeRequested`), which
    /// asks first when there is something to save. Says whether there was a document to close.
    @discardableResult
    func close() -> Bool {
        refresh()
        guard let close = model?.closeRequested else { return false }
        close()
        return true
    }

    /// The Edit menu's Redo, as `undo`.
    func redo() {
        if let field = Self.fieldBeingTyped() {
            field.undoManager?.redo()
        } else {
            refresh()
            model?.redo()
        }
    }

    /// The model of the document in front; nil when none is.
    private(set) var model: DocumentModel? {
        get { held?.model }
        set { held = newValue.map(Held.init) }
    }
    /// Holds the model weakly: the scene owns it.
    private var held: Held?

    private final class Held {
        weak var model: DocumentModel?
        init(_ model: DocumentModel) { self.model = model }
    }

    /// A document's screen on display: its model, and the scene its window is in. Both held weakly:
    /// the scene owns the model, and the system the scene.
    struct Display {
        weak var model: DocumentModel?
        weak var scene: AnyObject?
    }

    /// The documents' screens on display, the last shown last.
    @ObservationIgnored private var displays: [Display] = []

    /// The scene of the key window, the one the keyboard's commands and the menu bar act in, for a test
    /// to give; nil for the app's own (`keyWindowScene`).
    @ObservationIgnored var keyScene: (() -> AnyObject?)?
    /// The window that last became key, held weakly (`keyWindowScene`).
    @ObservationIgnored private weak var lastKeyWindow: UIWindow?

    /// `model`'s screen is on display in `scene` (its window's): it appeared, or came back on screen.
    func show(_ model: DocumentModel, in scene: AnyObject?) {
        displays.removeAll { $0.model == nil || $0.model === model }
        displays.append(Display(model: model, scene: scene))
        refresh()
    }

    /// `model`'s screen went: it is not on display any more.
    func leave(_ model: DocumentModel) {
        displays.removeAll { $0.model == nil || $0.model === model }
        refresh()
    }

    /// Finds the document in front again, from the key window's scene.
    func refresh() {
        let scene: AnyObject? = if let keyScene { keyScene() } else { Self.keyWindowScene(lastBecameKey: lastKeyWindow) }
        let front = Self.front(of: displays, keyScene: scene)
        if model !== front { model = front }
    }

    @objc private func windowBecameKey(_ notification: Notification) {
        if let window = notification.object as? UIWindow { lastKeyWindow = window }
        refresh()
    }

    /// The document in front among `displays`: the one shown in `keyScene`, the key window's, the last
    /// shown when several are (one closing as another opens). None when no window is key, or the key
    /// window's scene shows no document (the document browser, in a window of its own).
    static func front(of displays: [Display], keyScene: AnyObject?) -> DocumentModel? {
        guard let keyScene else { return nil }
        return displays.last { $0.scene === keyScene && $0.model != nil }?.model
    }

    /// The scene of the app's key window: `lastBecameKey`'s while it is still key, otherwise the scene
    /// with a key window; nil when no window is key.
    static func keyWindowScene(lastBecameKey: UIWindow?) -> UIWindowScene? {
        if let lastBecameKey, lastBecameKey.isKeyWindow, let scene = lastBecameKey.windowScene { return scene }
        return UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }
            .first { $0.windows.contains(where: \.isKeyWindow) }
    }
}

/// The Edit menu's Undo and Redo (the menu bar on an iPad, ⌘Z and ⇧⌘Z on a hardware keyboard), in
/// place of the system's. Those act on the scene's undo manager directly, and so would undo past
/// strokes, or text, waiting to be added (the strokes then refused as stale, and lost), and ⇧⌘Z would
/// redo while the toolbar's Redo is off. These go through the model, as the toolbar's buttons do,
/// under the same rule (`UndoAvailability`), named as the system's are ("Undo Add Markup":
/// `undoTitle`, `redoTitle`), or, while a field outside the pages is typed in, to that field
/// (`FrontDocument`), plain "Undo" and "Redo" then (the field's undo manager is not observed).
struct UndoRedoCommands: Commands {
    private var front: FrontDocument { FrontDocument.shared }

    var body: some Commands {
        let availability = front.model?.undoAvailability ?? UndoAvailability()
        let typing = front.fieldIsBeingTyped
        CommandGroup(replacing: .undoRedo) {
            Button(typing ? Strings.undo : availability.undoTitle) { front.undo() }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!(availability.undoEnabled || typing))
            Button(typing ? Strings.redo : availability.redoTitle) { front.redo() }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!(availability.redoEnabled || typing))
        }
    }
}

/// Where `FrontDocument.fieldBeingTyped` finds the first responder: it answers an action sent to no
/// one in particular, which UIKit hands to the first responder.
@MainActor
private enum FirstResponder {
    static var found: UIResponder?
}

extension UIResponder {
    @objc fileprivate func editinPDFReportFirstResponder() {
        FirstResponder.found = self
    }
}

/// The File menu's Save (⌘S on a hardware keyboard): Save for the document in front
/// (`FrontDocument.save`), while it has something to save. After the system's own items there (its Close,
/// ⌘W, which the app delegate routes to Back's question: `AppDelegate`), not in their place.
struct SaveCommands: Commands {
    private var front: FrontDocument { FrontDocument.shared }

    var body: some Commands {
        let canSave = front.model.map { $0.needsSave && !$0.isSaving } ?? false
        CommandGroup(after: .saveItem) {
            Button(Strings.saveDocument) { front.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!canSave)
        }
    }
}

/// "Edited" under the document's name, through SwiftUI's own line under the title (iOS 26 and later):
/// SwiftUI sets the navigation item again as the toolbar changes, and keeps its own line there. Before iOS
/// 26 the page indicator says it. (`DocumentHost.showEdited` sets the same line on the document's view
/// controller, for when that sets its navigation item again.)
struct EditedSubtitle: ViewModifier {
    let edited: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26, *) {
            content.navigationSubtitle(edited ? Strings.edited : "")
        } else {
            content
        }
    }
}

/// Keeps the app running in the background while some work runs (the recovery copy written as the
/// scene leaves the screen), for as long as the system allows.
@MainActor
enum BackgroundWork {
    /// One run's claim on the background time, given back once, when the work is done or the time is up.
    @MainActor
    private final class Claim {
        var task = UIBackgroundTaskIdentifier.invalid

        func end() {
            guard task != .invalid else { return }
            UIApplication.shared.endBackgroundTask(task)
            task = .invalid
        }
    }

    static func run(_ work: @escaping @MainActor () async -> Void) {
        let claim = Claim()
        claim.task = UIApplication.shared.beginBackgroundTask(withName: "Recovery copy") { claim.end() }
        Task {
            await work()
            claim.end()
        }
    }
}
