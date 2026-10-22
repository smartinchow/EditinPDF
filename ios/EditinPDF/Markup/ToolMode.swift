import EditinPDFCore
import Foundation
import Observation

/// What a touch on the page does in Markup mode. The model's `tool` is nil while the reader is only
/// reading; Markup in the toolbar sets it to `.select`, and the palette to any of these.
enum Tool: String, CaseIterable, Sendable {
    case select, highlight, underline, strikeout, ink, signature, textBox, note, rectangle, oval, line, arrow, eraser

    /// The tool's name: the palette button's title (and its VoiceOver label).
    var title: String {
        switch self {
        case .select: Strings.toolSelect
        case .highlight: Strings.highlight
        case .underline: Strings.underline
        case .strikeout: Strings.strikeout
        case .ink: Strings.toolInk
        case .signature: Strings.sign
        case .textBox: Strings.toolTextBox
        case .note: Strings.toolNote
        case .rectangle: Strings.toolRectangle
        case .oval: Strings.toolOval
        case .line: Strings.toolLine
        case .arrow: Strings.toolArrow
        case .eraser: Strings.toolEraser
        }
    }

    /// The SF Symbol of the tool's palette button.
    var systemImage: String {
        switch self {
        case .select: "cursorarrow"
        case .highlight: "highlighter"
        case .underline: "underline"
        case .strikeout: "strikethrough"
        case .ink: "scribble"
        case .signature: "signature"
        case .textBox: "textbox"
        case .note: "note.text"
        case .rectangle: "rectangle"
        case .oval: "circle"
        case .line: "line.diagonal"
        case .arrow: "arrow.up.right"
        case .eraser: "eraser"
        }
    }

    /// Whether the tool adds, changes or deletes annotations: everything but Select.
    var annotates: Bool { self != .select }
    /// Whether the tool has a style to pick (a colour at least): every tool that makes an annotation,
    /// but Sign, whose signature is always black and as wide (`SignatureStore.color`, `lineWidth`).
    var hasStyle: Bool { self != .select && self != .eraser && self != .signature }
    /// Whether the tool draws lines whose width can be picked.
    var usesWidth: Bool { [.ink, .rectangle, .oval, .line, .arrow].contains(self) }
    /// Whether the tool's text has a size to pick.
    var usesFontSize: Bool { self == .textBox }
    /// Whether the tool's shape can be filled.
    var usesFill: Bool { self == .rectangle || self == .oval }
    /// Whether one finger dragged across the page draws the tool's shape (`ShapeGeometry.draft`).
    var drawsShape: Bool { [.rectangle, .oval, .line, .arrow].contains(self) }
    /// Whether a tap on the page places what the tool makes: a box to type in, a note, or the saved
    /// signature.
    var placesByTap: Bool { self == .textBox || self == .note || self == .signature }

    /// The tool that makes text markup of `kind`: its colour is the one a mark of that kind is made in.
    init(markupKind kind: MarkupKind) {
        switch kind {
        case .highlight: self = .highlight
        case .underline: self = .underline
        case .strikeOut: self = .strikeout
        }
    }

    /// The text markup the tool makes over the text a finger drags across; nil for every other tool.
    var markupKind: MarkupKind? {
        switch self {
        case .highlight: .highlight
        case .underline: .underline
        case .strikeout: .strikeOut
        default: nil
        }
    }

    /// Why the tool cannot be used on a page turned by `pageRotation` degrees of a document that
    /// does (`canAnnotate`) or does not allow annotations; nil when it can be. The engine draws a
    /// text box upright in the page's own space, so on a turned page it would come out sideways.
    func refusal(canAnnotate: Bool, pageRotation: UInt32) -> String? {
        guard annotates else { return nil }
        if !canAnnotate { return Strings.markupNotAllowed }
        if self == .textBox, pageRotation % 360 != 0 { return Strings.textBoxNeedsUprightPage }
        return nil
    }
}

/// A colour without opacity, each component from 0 to 1: what a tool's style keeps, and what the
/// engine takes (`RgbColor`, which is not `Codable`).
struct RGBA: Codable, Equatable, Sendable {
    var r: Double
    var g: Double
    var b: Double

    /// The same colour for the engine.
    var rgbColor: RgbColor { RgbColor(red: r, green: g, blue: b) }
}

/// How a tool draws: its colour, its line width (points), its text size (points), whether a
/// shape is filled, and a text box's background and border. Every tool has all of them; the style
/// picker shows the ones the tool uses.
struct ToolStyle: Codable, Equatable, Sendable {
    var color: RGBA
    var width: Double
    var fontSize: Double
    var fill: Bool
    /// A text box's background; none when nil.
    var background: RGBA?
    /// Whether a text box has a border (`TextBoxFormat.borderWidth` wide, in its text's colour).
    var border: Bool

    init(color: RGBA, width: Double, fontSize: Double, fill: Bool, background: RGBA? = nil, border: Bool = false) {
        self.color = color
        self.width = width
        self.fontSize = fontSize
        self.fill = fill
        self.background = background
        self.border = border
    }

    private enum CodingKeys: String, CodingKey { case color, width, fontSize, fill, background, border }

    /// A style kept by an earlier version has no background and no border: it reads as none.
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        color = try values.decode(RGBA.self, forKey: .color)
        width = try values.decode(Double.self, forKey: .width)
        fontSize = try values.decode(Double.self, forKey: .fontSize)
        fill = try values.decode(Bool.self, forKey: .fill)
        background = try values.decodeIfPresent(RGBA.self, forKey: .background)
        border = try values.decodeIfPresent(Bool.self, forKey: .border) ?? false
    }

    /// The style a tool starts with, before the reader picks another.
    static func initial(for tool: Tool) -> ToolStyle {
        let black = RGBA(r: 0, g: 0, b: 0), red = RGBA(r: 0.9, g: 0.1, b: 0.1)
        let color: RGBA = switch tool {
        case .highlight: RGBA(r: 1, g: 0.9, b: 0)
        case .underline: RGBA(r: 0, g: 0.4, b: 1)
        case .strikeout, .rectangle, .oval, .line, .arrow: red
        case .note: RGBA(r: 1, g: 0.8, b: 0)
        case .select, .ink, .signature, .textBox, .eraser: black
        }
        return ToolStyle(color: color, width: 2, fontSize: 14, fill: false)
    }
}

/// Each tool's style, as the reader last left it: kept in `defaults` (JSON under "toolStyles"), so
/// every document, and the next launch, starts with it. Observable, so the palette shows a change
/// at once.
@MainActor
@Observable
final class ToolStyleStore {
    private static let key = "toolStyles"
    @ObservationIgnored private let defaults: UserDefaults
    private var styles: [String: ToolStyle]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Unreadable data (another version's, or damaged) is dropped: every tool starts over.
        styles = defaults.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode([String: ToolStyle].self, from: $0) } ?? [:]
    }

    /// Forgets every tool's style kept in `defaults`: each starts over from its first. (Debug builds use
    /// it so that each UI test starts from the first styles, whatever an earlier one picked.)
    static func forgetAll(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }

    subscript(tool: Tool) -> ToolStyle {
        get { styles[tool.rawValue] ?? .initial(for: tool) }
        set {
            guard newValue != self[tool] else { return }
            styles[tool.rawValue] = newValue
            if let data = try? JSONEncoder().encode(styles) { defaults.set(data, forKey: Self.key) }
        }
    }
}
