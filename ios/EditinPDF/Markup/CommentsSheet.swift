import EditinPDFCore
import SwiftUI

/// The document's comments and markup, listed page by page ("Page n"), top to bottom on a page
/// (`DocumentModel.commentRows`): each named for its kind, with its text and its author when it has
/// them. A tap on one jumps there (`jump`: the screen brings it into view and selects it, and the sheet
/// goes); a swipe deletes one the file does not lock, while the document allows markup. With none, it
/// says so (`Strings.noComments`). The list follows every change, undo and redo.
///
/// The text and the authors' names are the file's, shown as they are, and never logged.
struct CommentsSheet: View {
    let model: DocumentModel
    /// Why a change was not made, for the sheet to show while it is up (the screen's own alert waits).
    @Binding var failure: EditFailure?
    /// Brings `row`'s annotation into view and selects it; the screen puts the sheet away.
    let jump: (CommentRow) -> Void
    @Environment(\.dismiss) private var dismiss

    /// The rows, by page, in page order.
    private var pages: [(page: Int, rows: [CommentRow])] {
        let rows = DocumentModel.commentRows(model.annotationIndex)
        return Dictionary(grouping: rows, by: \.page).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// Whether the alert about a refused delete is up: while there is a failure to show.
    private var showsFailure: Binding<Bool> {
        Binding(get: { failure != nil }, set: { isShown in if !isShown { failure = nil } })
    }

    var body: some View {
        NavigationStack {
            Group {
                let pages = pages
                if pages.isEmpty {
                    ContentUnavailableView(Strings.noComments, systemImage: "text.bubble")
                        .accessibilityIdentifier("noComments")
                } else {
                    List {
                        ForEach(pages, id: \.page) { group in
                            Section(Strings.commentsPage(group.page + 1)) {
                                ForEach(group.rows) { row in rowView(row) }
                            }
                        }
                    }
                    .accessibilityIdentifier("commentsList")
                }
            }
            // A document scene puts its Back button on every navigation bar inside it (see
            // `PasswordSheet`); Done is the way out here.
            .navigationBarBackButtonHidden(true)
            .navigationTitle(Strings.comments)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.done) { dismiss() }
                        .accessibilityIdentifier("commentsDoneButton")
                }
            }
            .alert(failure?.title ?? "", isPresented: showsFailure, presenting: failure) { _ in
            } message: { failure in
                if !failure.message.isEmpty { Text(failure.message) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func rowView(_ row: CommentRow) -> some View {
        Button {
            jump(row)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Image(systemName: Self.symbol(of: row.kind))
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .foregroundStyle(.primary)
                    if let detail = row.detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(3)
                    }
                    if let author = row.author {
                        Text(author)
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        // Read as the list's text, not as a tinted button's.
        .tint(.primary)
        .accessibilityIdentifier("commentRow-\(row.page)-\(row.id.index)")
        .swipeActions(edge: .trailing) {
            if !row.isLocked, model.capabilities?.canAnnotate == true {
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
