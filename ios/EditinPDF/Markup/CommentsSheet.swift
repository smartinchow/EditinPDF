import EditinPDFCore
import SwiftUI

/// The document's comments: every mark and note, page by page ("Page n"), top to bottom on a page
/// (`DocumentModel.commentRows`). Each row leads with its comment (or a muted "Add a comment"), and
/// under it, small, the kind of mark and its page, its author when the file names one, and when it was
/// last changed. A filter at the top shows all the marks or only those with a comment (`CommentFilter`:
/// the latter to start with, when any has one). A tap on a row's text opens its comment to write or
/// change (a note's sheet for a note), over the list; the button beside it jumps there (`jump`: the
/// screen brings the mark into view and selects it, and the list goes). A swipe deletes one the file
/// does not lock, while the document allows markup. Add Comment, in the bar, closes the list and lets
/// the next tap on a page place a comment (`addComment`). With none, it says so (`Strings.noComments`).
/// The list follows every change, undo and redo.
///
/// The text and the authors' names are the file's, shown as they are, and never logged.
struct CommentsSheet: View {
    let model: DocumentModel
    /// Why a change was not made, for the sheet to show while it is up (the screen's own alert waits).
    @Binding var failure: EditFailure?
    /// Brings `row`'s annotation into view and selects it; the screen puts the sheet away.
    let jump: (CommentRow) -> Void
    /// Add Comment: the screen puts the sheet away and the next tap on a page places a comment.
    let addComment: () -> Void
    @Environment(\.dismiss) private var dismiss
    /// The filter picked; until one is, the one the rows start with (`CommentFilter.initial`).
    @State private var picked: CommentFilter?

    /// Whether the alert about a refused change is up: while there is a failure to show, and no comment
    /// sheet over the list, which shows its own.
    private var showsFailure: Binding<Bool> {
        Binding(get: { failure != nil && model.noteDraft == nil }, set: { isShown in if !isShown { failure = nil } })
    }

    /// The comment sheet over the list, while it is up.
    private var noteDraft: Binding<NoteDraft?> {
        Binding(get: { model.noteDraft }, set: { model.noteDraft = $0 })
    }

    private var canAnnotate: Bool { model.capabilities?.canAnnotate == true }

    var body: some View {
        NavigationStack {
            Group {
                let all = DocumentModel.commentRows(model.annotationIndex, dates: model.currentCommentDates)
                let filter = picked ?? CommentFilter.initial(for: all)
                let shown = filter.rows(all)
                Group {
                if all.isEmpty {
                    ContentUnavailableView(Strings.noComments, systemImage: "text.bubble")
                        .accessibilityIdentifier("noComments")
                } else {
                    List {
                        Section {
                            Picker(Strings.commentsFilter, selection: Binding(get: { filter }, set: { picked = $0 })) {
                                ForEach(CommentFilter.allCases) { choice in
                                    Text(choice.title).tag(choice)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                            .accessibilityIdentifier("commentsFilter")
                        }
                        if shown.isEmpty {
                            Text(Strings.noComments)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("noComments")
                        }
                        ForEach(Self.byPage(shown), id: \.page) { group in
                            Section(Strings.commentsPage(group.page + 1)) {
                                ForEach(group.rows) { row in rowView(row) }
                            }
                        }
                    }
                    .accessibilityIdentifier("commentsList")
                }
                }
                // The filter is chosen once, as the list opens: a comment written meanwhile does not
                // move the list to another filter on its own.
                .onAppear { if picked == nil { picked = CommentFilter.initial(for: all) } }
                // The dates as the file writes them, with their time zones: read as the list opens, and
                // again after each change while it is up, off the main thread.
                .task(id: model.revision) { await model.readCommentDates() }
            }
            // A document scene puts its Back button on every navigation bar inside it (see
            // `PasswordSheet`); Done is the way out here.
            .navigationBarBackButtonHidden(true)
            .navigationTitle(Strings.comments)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: addComment) {
                        Label(Strings.addComment, systemImage: "plus.bubble")
                    }
                    .disabled(!canAnnotate)
                    .accessibilityIdentifier("addCommentButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.done) { dismiss() }
                        .accessibilityIdentifier("commentsDoneButton")
                }
            }
            .alert(failure?.title ?? "", isPresented: showsFailure, presenting: failure) { _ in
            } message: { failure in
                if !failure.message.isEmpty { Text(failure.message) }
            }
            // A row's comment, written or changed over the list: Save changes it, and the sheet goes.
            .sheet(item: noteDraft) { draft in
                NoteEditorSheet(draft: draft, failure: $failure, save: { text in
                    await model.saveNoteDraft(text: text)
                }, cancel: {
                    model.noteDraft = nil
                }, written: { text in
                    model.noteTextDidChange(text)
                })
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// `rows`, by page, in page order.
    private static func byPage(_ rows: [CommentRow]) -> [(page: Int, rows: [CommentRow])] {
        Dictionary(grouping: rows, by: \.page).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func rowView(_ row: CommentRow) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                // A text box on a turned page is not edited here: the list jumps to it, and says why.
                if !canAnnotate || (!model.editComment(of: row) && model.failure != nil) { jump(row) }
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.headline)
                        .foregroundStyle(row.hasComment ? .primary : .secondary)
                        .italic(!row.hasComment)
                        .lineLimit(3)
                    HStack(spacing: 6) {
                        Image(systemName: Self.symbol(of: row.kind))
                            .accessibilityHidden(true)
                        Text(row.subtitle)
                        if let author = row.author {
                            Text(author)
                        }
                        if let modified = row.modified {
                            Text(CommentDate.text(for: modified))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("commentRow-\(row.page)-\(row.id.index)")
            Button {
                jump(row)
            } label: {
                Label(Strings.showOnPage, systemImage: "arrow.up.forward.circle")
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(row.showOnPageLabel)
            .accessibilityIdentifier("commentJump-\(row.page)-\(row.id.index)")
        }
        .swipeActions(edge: .trailing) {
            if !row.isLocked, canAnnotate {
                Button(role: .destructive) {
                    model.enqueueDelete(row.id)
                } label: {
                    Label(Strings.delete, systemImage: "trash")
                }
            }
        }
    }

    /// The SF Symbol shown beside a row of `kind`: its tool's, where it has one.
    private static func symbol(of kind: AnnotationKind) -> String {
        switch kind {
        case .note: Tool.note.systemImage
        case .highlight, .squiggly: Tool.highlight.systemImage
        case .underline: Tool.underline.systemImage
        case .strikeOut: Tool.strikeout.systemImage
        case .ink: Tool.ink.systemImage
        case .textBox: Tool.textBox.systemImage
        case .rectangle: Tool.rectangle.systemImage
        case .oval: Tool.oval.systemImage
        case .line: Tool.line.systemImage
        case .stamp: "seal"
        case .other: "text.bubble"
        }
    }
}
