import SwiftUI
import UIKit

/// Where the tool palette stands, by the width the scene has: a bar along the bottom on a compact
/// width (a phone, a folded iPhone Duo, a narrow Split View), a column at the leading edge on a
/// regular one (a tablet, an unfolded Duo). The screen reads its size class from the environment,
/// so the palette moves as soon as the width does.
enum PaletteLayout: Equatable {
    case bottomBar, sidePalette

    static func `for`(_ sizeClass: UserInterfaceSizeClass?) -> PaletteLayout {
        sizeClass == .regular ? .sidePalette : .bottomBar
    }
}

/// Markup mode's tools, and the button that opens the current tool's style: in a bar along the
/// bottom (the style in a sheet) or a column at the leading edge (the style in a popover). Tools
/// the document or the page refuses are disabled, and the palette says why. While strokes drawn with
/// Draw, or text typed in a text box, are waiting, Done stands before the style button.
struct ToolPalette: View {
    @Bindable var model: DocumentModel
    let layout: PaletteLayout
    @State private var showsStyle = false

    var body: some View {
        switch layout {
        case .bottomBar: bottomBar
        case .sidePalette: sidePalette
        }
    }

    // MARK: Layouts

    /// One row of tools that scrolls sideways when the width is short, the style button at its end,
    /// and why something is refused under it.
    private var bottomBar: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) { toolButtons }
                        .padding(.horizontal, 6)
                }
                Divider().frame(height: 28)
                doneDrawingButton
                styleButton
                    .padding(.trailing, 6)
                    .sheet(isPresented: $showsStyle) {
                        styleEditor
                            .frame(maxHeight: .infinity, alignment: .top)
                            .presentationDetents([.medium, .large])
                            .presentationDragIndicator(.visible)
                    }
            }
            refusalNote
                // Its own height, not the side palette's: unbounded, the note filled the page above
                // the bar and took the touches meant for it (seen on a turned page, Task 14).
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
        }
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolPalette")
    }

    /// A column of tools that scrolls when the height is short, the style button at its foot, and
    /// why something is refused beside it: a small panel at the column's top, as tall as its words,
    /// that touches go through to the page under it.
    private var sidePalette: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(spacing: 4) {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 2) { toolButtons }
                        .padding(.vertical, 6)
                }
                // As tall as the tools when there is room for them, and scrolling when there is not.
                .frame(maxHeight: CGFloat(Tool.allCases.count) * 42 + 12)
                Divider().frame(width: 28)
                doneDrawingButton
                styleButton
                    .padding(.bottom, 6)
                    .popover(isPresented: $showsStyle, arrowEdge: .leading) {
                        styleEditor
                            .frame(width: 320)
                            .presentationCompactAdaptation(.popover)
                    }
            }
            .padding(.horizontal, 6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if refusal != nil {
                refusalNote
                    .padding(10)
                    .frame(maxWidth: 220, alignment: .leading)
                    // Its own height: as tall as the tools, it covered a strip of the page and took the
                    // touches meant for it (Task 14).
                    .fixedSize(horizontal: false, vertical: true)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    // It only says something: a finger on it draws, scrolls or taps on the page under it.
                    .allowsHitTesting(false)
            }
        }
        .padding(.leading, 12)
        .padding(.vertical, 12)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolPalette")
    }

    // MARK: Parts

    @ViewBuilder private var toolButtons: some View {
        ForEach(Tool.allCases, id: \.self) { tool in
            let isCurrent = model.tool == tool
            Button {
                model.tool = tool
            } label: {
                Label(tool.title, systemImage: tool.systemImage)
                    .labelStyle(.iconOnly)
                    .font(.title3)
                    .frame(width: 40, height: 40)
                    .background(isCurrent ? Color.accentColor.opacity(0.2) : .clear,
                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .disabled(!model.canUse(tool))
            .accessibilityIdentifier("tool-\(tool.rawValue)")
            .accessibilityAddTraits(isCurrent ? .isSelected : [])
            .help(tool.title)
        }
    }

    /// Adds the strokes drawn with Draw to the page, as one drawing, and the text typed in a text box as
    /// a text box; there only while some are waiting.
    @ViewBuilder private var doneDrawingButton: some View {
        if model.hasPendingMarkup {
            Button {
                model.commitPendingInk()
            } label: {
                Label(Strings.doneDrawing, systemImage: "checkmark")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("doneDrawingButton")
            .help(Strings.doneDrawing)
        }
    }

    /// Opens the colour and size of the current tool; a dot of its colour sits on the icon.
    private var styleButton: some View {
        Button {
            showsStyle = true
        } label: {
            Label(Strings.toolStyle, systemImage: "paintpalette")
                .labelStyle(.iconOnly)
                .font(.title3)
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    if let tool = styledTool {
                        Circle()
                            .fill(model.toolStyles[tool].color.color)
                            .overlay(Circle().strokeBorder(.secondary, lineWidth: 0.5))
                            .frame(width: 12, height: 12)
                            .offset(x: -4, y: -4)
                    }
                }
                .contentShape(Rectangle())
        }
        .disabled(styledTool == nil)
        .accessibilityIdentifier("toolStyleButton")
        .help(Strings.toolStyle)
    }

    /// The current tool, when it has a style to pick and can be used.
    private var styledTool: Tool? {
        guard let tool = model.tool, tool.hasStyle, model.canUse(tool) else { return nil }
        return tool
    }

    @ViewBuilder private var styleEditor: some View {
        if let tool = model.tool, tool.hasStyle {
            ToolStyleEditor(tool: tool, store: model.toolStyles)
        }
    }

    /// Why tools are disabled: the whole document refusing markup comes first; otherwise a text box
    /// refused on a turned page.
    private var refusal: String? {
        model.refusal(of: .ink) ?? model.refusal(of: .textBox)
    }

    @ViewBuilder private var refusalNote: some View {
        if let refusal {
            Text(refusal)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier(refusal == Strings.markupNotAllowed ? "markupNotAllowed" : "textBoxNeedsUprightPage")
        }
    }
}

/// The colour, width, text size and fill of one tool: eight swatches and a colour well, then
/// whichever of the others the tool uses. Each change is kept at once.
struct ToolStyleEditor: View {
    let tool: Tool
    let store: ToolStyleStore

    /// The swatches, in the order of `Strings.styleSwatchNames`.
    static let swatches: [RGBA] = [
        RGBA(r: 0, g: 0, b: 0), RGBA(r: 0.5, g: 0.5, b: 0.5), RGBA(r: 0.9, g: 0.1, b: 0.1), RGBA(r: 1, g: 0.55, b: 0),
        RGBA(r: 1, g: 0.9, b: 0), RGBA(r: 0.1, g: 0.7, b: 0.2), RGBA(r: 0, g: 0.4, b: 1), RGBA(r: 0.55, g: 0.2, b: 0.85),
    ]

    private var style: Binding<ToolStyle> {
        Binding(get: { store[tool] }, set: { store[tool] = $0 })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(tool.title)
                .font(.headline)
            swatchRow
            ColorPicker(Strings.styleColor, selection: colorBinding, supportsOpacity: false)
                .accessibilityIdentifier("toolColorPicker")
            if tool.usesWidth {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(Strings.styleWidth)
                        Spacer()
                        Text(Strings.styleWidthValue(style.wrappedValue.width))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    // Kept to half points; without a `step`, which draws a tick for each.
                    Slider(value: halfPoints(style.width), in: 0.5...12) {
                        Text(Strings.styleWidth)
                    }
                    .accessibilityIdentifier("toolWidthSlider")
                }
            }
            if tool.usesFontSize {
                Stepper(Strings.styleFontSize(style.wrappedValue.fontSize), value: style.fontSize, in: 6...72)
                    .accessibilityIdentifier("toolFontSizeStepper")
            }
            if tool.usesFill {
                Toggle(Strings.styleFill, isOn: style.fill)
                    .accessibilityIdentifier("toolFillToggle")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var swatchRow: some View {
        HStack(spacing: 0) {
            ForEach(Array(zip(Self.swatches, Strings.styleSwatchNames).enumerated()), id: \.offset) { item in
                let (swatch, name) = item.element
                let isCurrent = style.wrappedValue.color == swatch
                Button {
                    style.wrappedValue.color = swatch
                } label: {
                    Circle()
                        .fill(swatch.color)
                        .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 0.5))
                        .padding(isCurrent ? 4 : 2)
                        .overlay(Circle().strokeBorder(isCurrent ? Color.accentColor : .clear, lineWidth: 2))
                        .frame(width: 34, height: 34)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(name)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityIdentifier("swatch-\(item.offset)")
            }
        }
    }

    /// `value`, rounded to the nearest half point as it is set.
    private func halfPoints(_ value: Binding<Double>) -> Binding<Double> {
        Binding(get: { value.wrappedValue }, set: { value.wrappedValue = ($0 * 2).rounded() / 2 })
    }

    private var colorBinding: Binding<Color> {
        Binding(get: { style.wrappedValue.color.color }, set: { style.wrappedValue.color = RGBA($0) })
    }
}

extension RGBA {
    /// The colour for SwiftUI.
    var color: Color { Color(red: r, green: g, blue: b) }

    /// `color` in sRGB, each component kept between 0 and 1 (a wide-gamut pick can fall outside).
    init(_ color: Color) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(color).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func clamped(_ value: CGFloat) -> Double { min(max(Double(value), 0), 1) }
        self.init(r: clamped(red), g: clamped(green), b: clamped(blue))
    }
}
