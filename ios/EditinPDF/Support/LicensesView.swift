import SwiftUI

/// The Licenses screen: the notices file (`Notices`) as a readable page, in a sheet with a Done button.
/// Headings are headings for VoiceOver, the text follows Dynamic Type, and the colors are the system's, so
/// it reads the same in light and dark mode.
struct LicensesView: View {
    @Environment(\.dismiss) private var dismiss
    /// The file's blocks; nil until read, empty when the app does not carry the file.
    @State private var blocks: [NoticesBlock]?

    var body: some View {
        NavigationStack {
            Group {
                if let blocks {
                    if blocks.isEmpty {
                        Text(Strings.licensesUnavailable)
                            .padding()
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                                    NoticesBlockView(block: block)
                                }
                            }
                            .padding()
                        }
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle(Strings.licenses)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.done) { dismiss() }
                        .accessibilityIdentifier("licensesDoneButton")
                }
            }
        }
        .task {
            // The file is long (a few hundred KB of text); read it off the main thread.
            blocks = await Task.detached(priority: .userInitiated) {
                Notices.bundledText().map(Notices.blocks(of:)) ?? []
            }.value
        }
    }
}

/// One block of the notices file.
private struct NoticesBlockView: View {
    let block: NoticesBlock

    var body: some View {
        switch block {
        case let .heading(level, text):
            Text(text)
                .font(Self.font(forHeadingLevel: level))
                .fontWeight(level >= 4 ? .semibold : .bold)
                .padding(.top, level <= 2 ? 12 : 4)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(Self.accessibilityLevel(level))
        case let .paragraph(text):
            Text(Self.inline(text))
                .font(.body)
        case let .bullet(text, indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\u{2022}")
                    .accessibilityHidden(true)
                Text(Self.inline(text))
            }
            .font(.callout)
            .padding(.leading, CGFloat(indent) * 20)
        case let .preformatted(text):
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private static func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: .title2
        case 2: .title3
        case 3: .headline
        default: .subheadline
        }
    }

    private static func accessibilityLevel(_ level: Int) -> AccessibilityHeadingLevel {
        switch level {
        case 1: .h1
        case 2: .h2
        case 3: .h3
        case 4: .h4
        default: .h5
        }
    }

    /// The text with its inline Markdown (`code`, **bold**) applied; as written when it does not parse.
    private static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}
