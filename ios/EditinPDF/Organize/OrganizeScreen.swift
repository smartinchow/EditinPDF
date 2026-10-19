import EditinPDFCore
import SwiftUI

/// Organize Pages: the document's pages in a grid (`PageGridViewController`), to select, drag into
/// another order, turn, delete, and add blank pages between. Every change goes through the model, so
/// it is one step of Undo in the main toolbar, and the pages and thumbnails follow it.
///
/// The actions are buttons with a title and an icon: in a bottom bar on a compact width, at the
/// trailing end of the top bar on a regular one (re-read when the width changes: split view, the
/// iPhone Duo). What they do, and when they can be used, is `OrganizeController`'s. A document that
/// does not allow its pages to be changed shows its pages with every action off, and says why.
struct OrganizeScreen: View {
    let model: DocumentModel
    let store: ThumbnailStore

    @State private var picksFile = false
    @State private var controller: OrganizeController
    @State private var confirmsDelete = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dismiss) private var dismiss

    init(model: DocumentModel, store: ThumbnailStore, documentName: String = Strings.untitledDocument) {
        self.model = model
        self.store = store
        _controller = State(initialValue: OrganizeController(model: model, documentName: documentName))
    }

    var body: some View {
        NavigationStack {
            PageGrid(model: model, store: store, controller: controller, revision: model.revision,
                     selection: controller.selection, canMove: controller.canMove,
                     canSelect: controller.canOrganize)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) { notAllowedFooter }
                // A document scene puts its Back button on every navigation bar inside it (see
                // ThumbnailsSheet); Done closes this screen.
                .navigationBarBackButtonHidden(true)
                .navigationTitle(controller.selection.isEmpty ? Strings.organize
                                 : Strings.pagesSelected(count: controller.selection.count))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
        }
        .confirmationDialog(Strings.deletePagesConfirm(count: controller.selection.count), isPresented: $confirmsDelete,
                            titleVisibility: .visible) {
            Button(Strings.delete, role: .destructive) { controller.deleteSelection() }
                .accessibilityIdentifier("organizeConfirmDelete")
        } message: {
            Text(Strings.deletePagesConfirmMessage)
        }
        // The document screen's alert is covered by this one: a change that was not made says why here.
        .alert(model.failure?.title ?? "", isPresented: showsEditFailure, presenting: model.failure) { _ in
        } message: { failure in
            if !failure.message.isEmpty { Text(failure.message) }
        }
        .fileImporter(isPresented: $picksFile, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { controller.insertFromFile(url) }
        }
        .onChange(of: model.lastChange) { controller.modelDidChange(model.lastChange) }
    }

    private var showsEditFailure: Binding<Bool> {
        Binding(
            get: { model.failure != nil },
            set: { isShown in if !isShown { model.failure = nil } }
        )
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(Strings.done) { dismiss() }
                .accessibilityIdentifier("organizeDone")
        }
        if sizeClass == .compact {
            ToolbarItemGroup(placement: .bottomBar) { actions }
        } else {
            ToolbarItemGroup(placement: .topBarTrailing) { actions }
        }
    }

    @ViewBuilder private var actions: some View {
        Button {
            controller.selectAll()
        } label: {
            Label(controller.allSelected ? Strings.deselectAll : Strings.selectAll, systemImage: "checkmark.circle")
        }
        .disabled(!controller.canOrganize || model.pageCount == 0)
        .accessibilityIdentifier("organizeSelectAll")

        Button {
            controller.rotate(by: -90)
        } label: {
            Label(Strings.rotateLeft, systemImage: "rotate.left")
        }
        .disabled(!controller.canRotate)
        .accessibilityIdentifier("organizeRotateLeft")

        Button {
            controller.rotate(by: 90)
        } label: {
            Label(Strings.rotateRight, systemImage: "rotate.right")
        }
        .disabled(!controller.canRotate)
        .accessibilityIdentifier("organizeRotateRight")

        Button {
            if controller.selection.count > 1 { confirmsDelete = true } else { controller.deleteSelection() }
        } label: {
            Label(Strings.delete, systemImage: "trash")
        }
        .disabled(!controller.canDelete)
        .accessibilityIdentifier("organizeDelete")

        Button {
            controller.insertBlank()
        } label: {
            Label(Strings.insertBlank, systemImage: "doc.badge.plus")
        }
        .disabled(!controller.canInsertBlank)
        .accessibilityIdentifier("organizeInsertBlank")

        Button {
            picksFile = true
        } label: {
            Label(Strings.insertFromFile, systemImage: "doc.badge.arrow.up")
        }
        .disabled(!controller.canInsertFile)
        .accessibilityIdentifier("organizeInsertFile")

        // The share sheet offers Save to Files. With no page selected there is nothing to share.
        if let item = controller.extractedPages() {
            ShareLink(item: item, preview: SharePreview(item.fileName)) {
                Label(Strings.extract, systemImage: "square.and.arrow.up")
            }
            .accessibilityIdentifier("organizeExtract")
        } else {
            Button {} label: {
                Label(Strings.extract, systemImage: "square.and.arrow.up")
            }
            .disabled(true)
            .accessibilityIdentifier("organizeExtract")
        }
    }

    /// Says why nothing can be changed, for a document that does not allow it.
    @ViewBuilder private var notAllowedFooter: some View {
        if controller.organizeIsRefused || (model.isEncrypted && controller.canExtract) {
            Text(controller.organizeIsRefused ? Strings.organizeNotAllowed : Strings.extractUnprotectedNote)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.regularMaterial)
                .accessibilityIdentifier(controller.organizeIsRefused ? "organizeNotAllowed" : "organizeExtractNote")
        }
    }
}

/// `PageGridViewController` in SwiftUI. The revision, the selection and whether pages can be moved
/// are passed in, so the screen's body reads them and the controller is updated whenever they change.
private struct PageGrid: UIViewControllerRepresentable {
    let model: DocumentModel
    let store: ThumbnailStore
    let controller: OrganizeController
    let revision: UInt64
    let selection: Set<Int>
    let canMove: Bool
    let canSelect: Bool

    func makeUIViewController(context: Context) -> PageGridViewController {
        let grid = PageGridViewController(model: model, store: store)
        let controller = controller
        grid.selection = selection
        grid.onSelectionChange = { controller.selection = $0 }
        grid.onMove = { pages, dropIndex in controller.move(pages, dropIndex: dropIndex) }
        return grid
    }

    func updateUIViewController(_ grid: PageGridViewController, context: Context) {
        grid.canMove = canMove
        grid.canSelect = canSelect
        // The new pages first, then the selection on them. A selection made here, not by a tap on the
        // grid (an inserted page, moved pages), is brought into view.
        _ = revision
        grid.update()
        if selection != grid.selection {
            let added = selection.subtracting(grid.selection)
            grid.selection = selection
            grid.reveal(added)
        }
    }
}
