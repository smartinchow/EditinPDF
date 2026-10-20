import PencilKit
import SwiftUI
import UIKit

/// The pad the reader draws their signature in, with a finger or the Apple Pencil: a black pen on
/// white, along a line marked "Sign here". Save keeps it (`DocumentModel.saveSignature`) for Sign to
/// place with a tap; Clear wipes what was drawn, to start again; Cancel leaves the saved signature as
/// it was. Save is there once what is drawn is a signature: something, not a dot.
///
/// It takes the whole height of the screen on an iPhone, so there is room to sign, upright or on its
/// side. A swipe never puts it away (a stroke drawn downwards would pull the sheet down with it):
/// Cancel and Save are the ways out. A save that fails says why over the pad (`failure`), which stays
/// with what was drawn.
///
/// What is drawn is the reader's signature: it is never logged.
struct SignaturePadSheet: View {
    /// Why the signature was not saved, for the pad to show while it is up (the screen's alert waits).
    @Binding var failure: EditFailure?
    /// Keeps the signature drawn, and says whether it was kept (the model puts the pad away when it is).
    let save: (SavedSignature) -> Bool
    /// Closes the pad; nothing changes.
    let cancel: () -> Void

    @State private var drawing = PKDrawing()
    /// What is drawn, as a signature; nil while it is none (nothing, or a dot).
    @State private var signature: SavedSignature?

    /// The width of the pen on the pad, in points.
    static let penWidth: CGFloat = 4
    /// How far down the pad the line to sign along is, as a part of its height.
    nonisolated static let baseline: CGFloat = 0.65

    /// `drawing` (in the pad's points) as a signature: each stroke's path sampled every point along it,
    /// so its curves are kept, not only the points its spline is controlled by (`InkGeometry.strokes`),
    /// then normalised (`SignatureStore.normalise`). Nil for nothing drawn, or a dot.
    static func signature(of drawing: PKDrawing) -> SavedSignature? {
        let strokes = InkGeometry.strokes(of: drawing, canvasOrigin: .zero, pointsPerCanvasPoint: 1, spacing: 1, tolerance: 0.25)
        return SignatureStore.normalise(strokes)
    }

    /// Whether the alert about a save that failed is up: while there is a failure to show.
    private var showsFailure: Binding<Bool> {
        Binding(get: { failure != nil }, set: { isShown in if !isShown { failure = nil } })
    }

    /// The drawing, kept with what it is as a signature whenever the pad changes it.
    private var drawingBinding: Binding<PKDrawing> {
        Binding(get: { drawing }, set: { newDrawing in
            drawing = newDrawing
            signature = Self.signature(of: newDrawing)
        })
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                pad
                Button {
                    drawing = PKDrawing()
                    signature = nil
                } label: {
                    Label(Strings.clear, systemImage: "trash")
                }
                .disabled(drawing.strokes.isEmpty)
                .accessibilityIdentifier("signatureClearButton")
            }
            .padding(16)
            // A document scene puts its Back button on every navigation bar inside it (see
            // `PasswordSheet`): here it would leave what was drawn without saying so.
            .navigationBarBackButtonHidden(true)
            .navigationTitle(Strings.signatureTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(action: cancel) {
                        Label(Strings.cancel, systemImage: "xmark")
                    }
                    .accessibilityIdentifier("signatureCancelButton")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        if let signature { _ = save(signature) }
                    } label: {
                        Label(Strings.save, systemImage: "checkmark")
                    }
                    .disabled(signature == nil)
                    .accessibilityIdentifier("signatureSaveButton")
                }
            }
            // A save refused: why, over the pad, which stays with what was drawn.
            .alert(failure?.title ?? "", isPresented: showsFailure, presenting: failure) { _ in
            } message: { failure in
                if !failure.message.isEmpty { Text(failure.message) }
            }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(true)
    }

    /// White paper with the line to sign along, and the canvas over it.
    private var pad: some View {
        ZStack {
            Color.white
            GeometryReader { geometry in
                let y = geometry.size.height * Self.baseline
                Path { path in
                    path.move(to: CGPoint(x: 24, y: y))
                    path.addLine(to: CGPoint(x: max(geometry.size.width - 24, 24), y: y))
                }
                .stroke(Color(white: 0.6), style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                // Under the line's start (a geometry reader puts its content at its top-left).
                Text(Strings.signHere)
                    .font(.footnote)
                    .foregroundStyle(Color(white: 0.45))
                    .offset(x: 24, y: y + 6)
            }
            .accessibilityHidden(true)
            SignatureCanvas(drawing: drawingBinding)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(white: 0.8)))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The canvas of the signature pad: PencilKit, drawn on by a finger or the Apple Pencil with a black
/// pen, over the pad's paper. It tells `drawing` of each change, and is emptied when `drawing` is.
private struct SignatureCanvas: UIViewRepresentable {
    @Binding var drawing: PKDrawing

    func makeUIView(context: Context) -> SignatureCanvasView {
        let canvas = SignatureCanvasView()
        canvas.drawingPolicy = .anyInput
        canvas.tool = PKInkingTool(.pen, color: .black, width: SignaturePadSheet.penWidth)
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        // Black stays black: PencilKit shows ink in the dark appearance's colours otherwise.
        canvas.overrideUserInterfaceStyle = .light
        canvas.isScrollEnabled = false
        canvas.bounces = false
        canvas.scrollsToTop = false
        canvas.delegate = context.coordinator
        canvas.isAccessibilityElement = true
        canvas.accessibilityLabel = Strings.signatureCanvas
        canvas.accessibilityTraits = .allowsDirectInteraction
        canvas.accessibilityIdentifier = "signatureCanvas"
        return canvas
    }

    func updateUIView(_ canvas: SignatureCanvasView, context: Context) {
        // Clear: the pad's drawing was emptied.
        guard drawing.strokes.isEmpty, !canvas.drawing.strokes.isEmpty else { return }
        context.coordinator.isClearing = true
        canvas.drawing = PKDrawing()
        canvas.forgetStrokes()
        context.coordinator.isClearing = false
    }

    func makeCoordinator() -> Coordinator { Coordinator(drawing: $drawing) }

    @MainActor
    final class Coordinator: NSObject, PKCanvasViewDelegate {
        let drawing: Binding<PKDrawing>
        /// Set while the canvas is emptied for Clear: the pad emptied its drawing already.
        var isClearing = false

        init(drawing: Binding<PKDrawing>) {
            self.drawing = drawing
        }

        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            // A drawing only moved or shrunk to stay in view is the same signature.
            guard !isClearing, (canvasView as? SignatureCanvasView)?.isKeepingInView != true else { return }
            drawing.wrappedValue = canvasView.drawing
        }
    }
}

/// The pad's PencilKit canvas, with an undo manager of its own: a stroke drawn is registered there,
/// never on the document's, whose Undo would otherwise take back strokes drawn in the pad.
///
/// When the pad changes size (the phone turned on its side, a window resized), what is drawn keeps
/// its place on the line to sign along, and is shrunk if it no longer fits (`keepingInView`): turned
/// from upright to its side, a pad is wider and much lower, and a signature left where it was would
/// be out of sight.
final class SignatureCanvasView: PKCanvasView {
    private let localUndo = UndoManager()
    override var undoManager: UndoManager? { localUndo }
    /// The size the drawing was last laid out for; zero before the first layout.
    private var laidOutSize: CGSize = .zero
    /// Set while the drawing is moved to stay in view.
    private(set) var isKeepingInView = false

    /// Forgets the strokes drawn and taken back: Clear starts afresh.
    func forgetStrokes() {
        localUndo.removeAllActions()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = bounds.size
        defer { laidOutSize = size }
        guard laidOutSize.width > 0, laidOutSize.height > 0, size.width > 0, size.height > 0, size != laidOutSize,
              !drawing.strokes.isEmpty else { return }
        isKeepingInView = true
        drawing = drawing.transformed(using: Self.keepingInView(drawing.bounds, from: laidOutSize, to: size))
        isKeepingInView = false
    }

    /// How what is drawn within `drawn` on a pad `old` in size moves when the pad becomes `new` in size:
    /// the point on the line to sign along, in the middle (`SignaturePadSheet.baseline`), stays that
    /// point, and the drawing is shrunk about it, if need be, until it is within the pad again.
    nonisolated static func keepingInView(_ drawn: CGRect, from old: CGSize, to new: CGSize) -> CGAffineTransform {
        let from = CGPoint(x: old.width / 2, y: old.height * SignaturePadSheet.baseline)
        let to = CGPoint(x: new.width / 2, y: new.height * SignaturePadSheet.baseline)
        let moved = drawn.offsetBy(dx: to.x - from.x, dy: to.y - from.y)
        var scale: CGFloat = 1
        // Each side out of the pad brings the drawing in about the anchor until it is on the edge.
        if moved.minX < 0 { scale = min(scale, to.x / (to.x - moved.minX)) }
        if moved.maxX > new.width { scale = min(scale, (new.width - to.x) / (moved.maxX - to.x)) }
        if moved.minY < 0 { scale = min(scale, to.y / (to.y - moved.minY)) }
        if moved.maxY > new.height { scale = min(scale, (new.height - to.y) / (moved.maxY - to.y)) }
        if !scale.isFinite || scale <= 0 { scale = 1 }
        return CGAffineTransform(translationX: to.x, y: to.y).scaledBy(x: scale, y: scale).translatedBy(x: -from.x, y: -from.y)
    }
}
