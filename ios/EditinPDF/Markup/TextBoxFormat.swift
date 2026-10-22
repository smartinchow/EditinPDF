import EditinPDFCore
import SwiftUI
import UIKit

/// A text box's look, as the reader picks it: its text's size and colour, its background, and its
/// border. What the format bar over the keyboard (`TextBoxFormatBar`) and Select's Format
/// (`TextBoxFormatSheet`) change, what a new text box is made with (`Edit.addTextBox`) and what one on
/// the page is given (`Edit.restyleTextBox`). Bold, italic, alignment and the face are not here: the
/// engine sets every text box in Helvetica, aligned as the file says.
struct TextBoxFormat: Equatable, Sendable {
    /// The text's size, in points: held to what the bridge takes (`ShapeGeometry.fontSize`).
    var fontSize: Double
    var color: RGBA
    /// The box's background; none when nil.
    var background: RGBA?
    /// How wide the box's border is, in points, drawn in the text's colour: 0 for none, else 0.5
    /// through 12 (what the bridge takes).
    var borderWidth: Double

    /// The sizes the format's Smaller and Larger step through, in points: 6 through 72.
    static let sizeSteps: [Double] = [6, 7, 8, 9, 10, 11, 12, 14, 16, 18, 20, 24, 28, 32, 36, 40, 48, 60, 72]
    /// How wide a border the format's Border switch draws, in points.
    static let borderOn: Double = 1
    /// The widths of a border the bridge takes, besides none.
    static let borderWidths: ClosedRange<Double> = 0.5...12
    /// The background colours offered, in the order of `Strings.backgroundNames`: pale enough for the
    /// text, in any of the swatches' colours, to read on them.
    static let backgrounds: [RGBA] = [
        RGBA(r: 1, g: 0.97, b: 0.74), RGBA(r: 0.86, g: 0.93, b: 1), RGBA(r: 0.87, g: 0.96, b: 0.87),
        RGBA(r: 1, g: 0.9, b: 0.93), RGBA(r: 1, g: 1, b: 1),
    ]

    init(fontSize: Double, color: RGBA, background: RGBA? = nil, borderWidth: Double = 0) {
        self.fontSize = ShapeGeometry.fontSize(fontSize)
        self.color = color
        self.background = background
        self.borderWidth = Self.heldBorder(borderWidth)
    }

    /// The look Text Box makes a new text box with: its style's.
    init(style: ToolStyle) {
        self.init(fontSize: style.fontSize, color: style.color, background: style.background,
                  borderWidth: style.border ? Self.borderOn : 0)
    }

    /// The look of `info`, a text box on a page, as the engine draws it (`AnnotationInfo.fontSize`,
    /// `color`, `fill`, `borderWidth`); what the file does not say is `style`'s (Text Box's).
    init(_ info: AnnotationInfo, otherwise style: ToolStyle) {
        self.init(fontSize: info.fontSize ?? style.fontSize,
                  color: info.color.map { RGBA(r: $0.red, g: $0.green, b: $0.blue) } ?? style.color,
                  background: info.fill.map { RGBA(r: $0.red, g: $0.green, b: $0.blue) },
                  borderWidth: info.borderWidth ?? 0)
    }

    /// `width` as a border the bridge takes: none for nothing, a number that is not one or less than
    /// none; else held to `borderWidths`.
    static func heldBorder(_ width: Double) -> Double {
        guard width.isFinite, width > 0 else { return 0 }
        return min(max(width, borderWidths.lowerBound), borderWidths.upperBound)
    }

    /// Whether the box has a border. Switched on, it is `borderOn` wide; a border the box already had
    /// keeps its width.
    var hasBorder: Bool {
        get { borderWidth > 0 }
        set { borderWidth = newValue ? (borderWidth > 0 ? borderWidth : Self.borderOn) : 0 }
    }

    /// The next size of `sizeSteps` above the text's, nil at 72 or more.
    var largerSize: Double? { Self.sizeSteps.first { $0 > fontSize + 0.01 } }
    /// The next size of `sizeSteps` below the text's, nil at 6 or less.
    var smallerSize: Double? { Self.sizeSteps.last { $0 < fontSize - 0.01 } }

    /// The text one step larger (`largerSize`); no change at the largest.
    mutating func grow() {
        if let larger = largerSize { fontSize = larger }
    }

    /// The text one step smaller (`smallerSize`); no change at the smallest.
    mutating func shrink() {
        if let smaller = smallerSize { fontSize = smaller }
    }

    /// `style` with this look: the size, colour, background and whether there is a border. What Text
    /// Box keeps for the next text box.
    func applied(to style: ToolStyle) -> ToolStyle {
        var style = style
        style.fontSize = fontSize
        style.color = color
        style.background = background
        style.border = hasBorder
        return style
    }

    /// The edit that gives the text box `ref` names this look.
    func restyle(_ ref: AnnotationRef) -> Edit? {
        guard let page = UInt32(exactly: ref.page) else { return nil }
        return .restyleTextBox(page: page, index: ref.index, fontSize: fontSize, color: color.rgbColor,
                               fill: background?.rgbColor, borderWidth: borderWidth)
    }

    /// Where the engine sets the text in from the box's edges, in points: 2, and the border's width.
    var textInset: CGFloat { ShapeGeometry.textInset + CGFloat(borderWidth) }
}

/// The look being picked for the text box being typed in, which the format bar over the keyboard
/// changes and the box follows (`changed`). Observable, so the bar shows a change at once.
@MainActor
@Observable
final class TextBoxFormatState {
    /// The look picked; the box is told of every change (`changed`).
    var format: TextBoxFormat {
        didSet {
            if format != oldValue { changed?(format) }
        }
    }

    /// Told of every change of `format`.
    @ObservationIgnored var changed: ((TextBoxFormat) -> Void)?
    /// Opens the system's colour picker for the text (More Colors…).
    @ObservationIgnored var pickColor: (() -> Void)?

    init(_ format: TextBoxFormat) {
        self.format = format
    }

    /// The swatch of `ToolStyleEditor.swatches` the text's colour is, if it is one (`RGBA.matches`).
    var swatch: Int? { ToolStyleEditor.swatches.firstIndex { $0.matches(format.color) } }
    /// The background of `TextBoxFormat.backgrounds` the box has: -1 for none, nil for one not offered.
    var backgroundChoice: Int? {
        guard let background = format.background else { return -1 }
        return TextBoxFormat.backgrounds.firstIndex { $0.matches(background) }
    }
}

extension RGBA {
    /// Whether `other` is this colour as a file keeps it: each component within a 255th. A colour read
    /// back from a file has been through the engine's single precision and its rounding.
    func matches(_ other: RGBA) -> Bool {
        abs(r - other.r) < 0.004 && abs(g - other.g) < 0.004 && abs(b - other.b) < 0.004
    }
}

/// A small round picture of `color`, drawn as it is (not tinted), for a menu item.
@MainActor
func swatchImage(_ color: RGBA, slashed: Bool = false) -> UIImage {
    let side: CGFloat = 22
    return UIGraphicsImageRenderer(size: CGSize(width: side, height: side)).image { context in
        let circle = CGRect(x: 1, y: 1, width: side - 2, height: side - 2)
        color.uiColor.setFill()
        context.cgContext.fillEllipse(in: circle)
        UIColor.systemGray.setStroke()
        context.cgContext.setLineWidth(1)
        context.cgContext.strokeEllipse(in: circle.insetBy(dx: 0.5, dy: 0.5))
        if slashed {
            context.cgContext.move(to: CGPoint(x: 4, y: side - 4))
            context.cgContext.addLine(to: CGPoint(x: side - 4, y: 4))
            context.cgContext.strokePath()
        }
    }.withRenderingMode(.alwaysOriginal)
}

/// The bar over the keyboard while a text box is typed in: Smaller and Larger with the text's size
/// between them, the text's colour (the eight swatches, and More Colors…), the background (none, or
/// one of `TextBoxFormat.backgrounds`) and Border. Every change shows in the box at once
/// (`TextBoxFormatState.changed`), and is made when the box is.
struct TextBoxFormatBar: View {
    @Bindable var state: TextBoxFormatState

    var body: some View {
        HStack(spacing: 2) {
            Button {
                state.format.shrink()
            } label: {
                Label(Strings.smallerText, systemImage: "textformat.size.smaller")
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .disabled(state.format.smallerSize == nil)
            .accessibilityValue(Strings.textSizeValue(state.format.fontSize))
            .accessibilityIdentifier("formatSmallerButton")
            Text(Strings.textSizeValue(state.format.fontSize))
                .font(.footnote.monospacedDigit())
                .frame(minWidth: 44)
                .accessibilityLabel(Strings.textSize)
                .accessibilityValue(Strings.textSizeValue(state.format.fontSize))
                .accessibilityIdentifier("formatSizeValue")
            Button {
                state.format.grow()
            } label: {
                Label(Strings.largerText, systemImage: "textformat.size.larger")
                    .labelStyle(.iconOnly)
                    .frame(width: 40, height: 40)
                    .contentShape(Rectangle())
            }
            .disabled(state.format.largerSize == nil)
            .accessibilityValue(Strings.textSizeValue(state.format.fontSize))
            .accessibilityIdentifier("formatLargerButton")
            Divider().frame(height: 24).padding(.horizontal, 4)
            colorMenu
            backgroundMenu
            Toggle(isOn: $state.format.hasBorder) {
                Label(Strings.border, systemImage: "square.dashed")
                    .labelStyle(.iconOnly)
                    .frame(width: 32, height: 32)
            }
            .toggleStyle(.button)
            .accessibilityIdentifier("formatBorderToggle")
            Spacer(minLength: 0)
        }
        .font(.title3)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, minHeight: 48)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Strings.formatTextBox)
        .accessibilityIdentifier("textBoxFormatBar")
    }

    /// The text's colour: the eight swatches, the one the text is checked, and More Colors….
    private var colorMenu: some View {
        Menu {
            Picker(Strings.textColor, selection: Binding(get: { state.swatch }, set: { picked in
                if let picked, ToolStyleEditor.swatches.indices.contains(picked) { state.format.color = ToolStyleEditor.swatches[picked] }
            })) {
                ForEach(Array(zip(ToolStyleEditor.swatches, Strings.styleSwatchNames).enumerated()), id: \.offset) { item in
                    Label {
                        Text(item.element.1)
                    } icon: {
                        Image(uiImage: swatchImage(item.element.0))
                    }
                    .tag(Optional(item.offset))
                    .accessibilityIdentifier("formatColor-\(item.offset)")
                }
            }
            .pickerStyle(.inline)
            Button {
                state.pickColor?()
            } label: {
                Label(Strings.moreColors, systemImage: "paintpalette")
            }
            .accessibilityIdentifier("formatMoreColorsButton")
        } label: {
            Label {
                Text(Strings.textColor)
            } icon: {
                Image(uiImage: swatchImage(state.format.color))
            }
            .labelStyle(.iconOnly)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("formatColorMenu")
    }

    /// The background: none, or one of `TextBoxFormat.backgrounds`, the one the box has checked.
    private var backgroundMenu: some View {
        Menu {
            Picker(Strings.background, selection: Binding(get: { state.backgroundChoice }, set: { picked in
                guard let picked else { return }
                state.format.background = TextBoxFormat.backgrounds.indices.contains(picked) ? TextBoxFormat.backgrounds[picked] : nil
            })) {
                Label(Strings.noBackground, systemImage: "circle.slash")
                    .tag(Optional(-1))
                    .accessibilityIdentifier("formatBackground-none")
                ForEach(Array(zip(TextBoxFormat.backgrounds, Strings.backgroundNames).enumerated()), id: \.offset) { item in
                    Label {
                        Text(item.element.1)
                    } icon: {
                        Image(uiImage: swatchImage(item.element.0))
                    }
                    .tag(Optional(item.offset))
                    .accessibilityIdentifier("formatBackground-\(item.offset)")
                }
            }
            .pickerStyle(.inline)
        } label: {
            Label {
                Text(Strings.background)
            } icon: {
                Image(uiImage: swatchImage(state.format.background ?? RGBA(r: 1, g: 1, b: 1), slashed: state.format.background == nil))
            }
            .labelStyle(.iconOnly)
            .frame(width: 40, height: 40)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("formatBackgroundMenu")
    }
}

/// The format's controls laid out in rows, for a sheet or a popover: the text's size, its colour (the
/// eight swatches and a colour well), the background (none, or one of `TextBoxFormat.backgrounds`)
/// and Border. Select's Format (`TextBoxFormatSheet`) and Text Box's style (`ToolStyleEditor`) show it.
struct TextBoxFormatPanel: View {
    @Binding var format: TextBoxFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Stepper {
                Text(Strings.styleFontSize(format.fontSize))
            } onIncrement: {
                format.grow()
            } onDecrement: {
                format.shrink()
            }
            .accessibilityIdentifier("formatSizeStepper")
            VStack(alignment: .leading, spacing: 8) {
                Text(Strings.textColor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                swatchRow(ToolStyleEditor.swatches, names: Strings.styleSwatchNames, current: format.color,
                          identifier: "formatColor") { format.color = $0 }
                ColorPicker(Strings.styleColor, selection: Binding(get: { format.color.color }, set: { format.color = RGBA($0) }),
                            supportsOpacity: false)
                    .accessibilityIdentifier("formatColorPicker")
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(Strings.background)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    swatchButton(RGBA(r: 1, g: 1, b: 1), slashed: true, name: Strings.noBackground, isCurrent: format.background == nil,
                                 identifier: "formatBackground-none") { format.background = nil }
                    ForEach(Array(zip(TextBoxFormat.backgrounds, Strings.backgroundNames).enumerated()), id: \.offset) { item in
                        swatchButton(item.element.0, slashed: false, name: item.element.1,
                                     isCurrent: format.background.map(item.element.0.matches) ?? false,
                                     identifier: "formatBackground-\(item.offset)") { format.background = item.element.0 }
                    }
                }
            }
            Toggle(Strings.border, isOn: $format.hasBorder)
                .accessibilityIdentifier("formatBorderToggle")
        }
    }

    private func swatchRow(_ colors: [RGBA], names: [String], current: RGBA?, identifier: String,
                           pick: @escaping (RGBA) -> Void) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(zip(colors, names).enumerated()), id: \.offset) { item in
                swatchButton(item.element.0, slashed: false, name: item.element.1, isCurrent: current.map(item.element.0.matches) ?? false,
                             identifier: "\(identifier)-\(item.offset)") { pick(item.element.0) }
            }
        }
    }

    private func swatchButton(_ color: RGBA, slashed: Bool, name: String, isCurrent: Bool, identifier: String,
                              pick: @escaping () -> Void) -> some View {
        Button(action: pick) {
            swatch(color, slashed: slashed, isCurrent: isCurrent)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .accessibilityIdentifier(identifier)
    }

    private func swatch(_ color: RGBA, slashed: Bool, isCurrent: Bool) -> some View {
        Circle()
            .fill(color.color)
            .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
            .overlay {
                if slashed {
                    Image(systemName: "line.diagonal")
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(90))
                }
            }
            .padding(isCurrent ? 4 : 2)
            .overlay(Circle().strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
            .frame(width: 34, height: 34)
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
    }
}

/// What Select's Format opens the format sheet for (`DocumentModel.formatDraft`): a text box on its
/// page, the look it has, and the revision it was read at, which the change is worked out against.
struct TextBoxFormatDraft: Identifiable, Equatable {
    let id = UUID()
    let ref: AnnotationRef
    let format: TextBoxFormat
    let revision: UInt64
}

/// The sheet Select's Format opens over a text box: the format's controls (`TextBoxFormatPanel`),
/// starting from the look the text box has; Apply gives it the look picked, one change named
/// `Strings.formatTextBox`, and Cancel leaves it as it was. Apply is there once something is changed.
struct TextBoxFormatSheet: View {
    let draft: TextBoxFormatDraft
    /// Gives the text box the look picked (the model puts the sheet away).
    let apply: (TextBoxFormat) -> Void
    /// Closes the sheet; nothing changes.
    let cancel: () -> Void

    @State private var format: TextBoxFormat

    init(draft: TextBoxFormatDraft, apply: @escaping (TextBoxFormat) -> Void, cancel: @escaping () -> Void) {
        self.draft = draft
        self.apply = apply
        self.cancel = cancel
        _format = State(initialValue: draft.format)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TextBoxFormatPanel(format: $format)
                    .padding(20)
            }
            // A document scene puts its Back button on every navigation bar inside it (see
            // `PasswordSheet`); Cancel and Apply are the ways out.
            .navigationBarBackButtonHidden(true)
            .navigationTitle(Strings.formatTextBox)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(Strings.cancel, action: cancel)
                        .accessibilityIdentifier("formatCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(Strings.apply) { apply(format) }
                        .disabled(format == draft.format)
                        .accessibilityIdentifier("formatApplyButton")
                }
            }
        }
        .presentationDetents([.medium, .large])
        .accessibilityIdentifier("textBoxFormatSheet")
    }
}
