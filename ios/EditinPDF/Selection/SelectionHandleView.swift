import UIKit

/// One of the two handles at the ends of the selected text: a thin line along the text's line, with a
/// round knob past its end, above the line for the handle at the start of the selection and below it
/// for the one at the end, in the app's accent colour. Dragging one moves that end of the selection.
///
/// A handle is a sibling of the zooming content view, not inside it: it stays the same size as the
/// page is zoomed, and only its place follows the text. It is the knob and the line, with room round
/// them to be grabbed by: a disc `touchWidth` across round the knob, and a few points either side of
/// the line. The view's frame is a box round those, and a touch in the box but outside them is not the
/// handle's: it falls through to the page, so a long press or a tap on the text near a handle is still
/// one on the text. Where the two handles' rooms overlap, as they do on a short selection, a touch is
/// the handle's whose knob or line it is nearer to.
final class SelectionHandleView: UIView {
    /// Which end of the selected text the handle is at.
    typealias Edge = SelectionHandle

    /// The knob's diameter.
    static let knobDiameter: CGFloat = 10
    /// The line's width.
    static let stemWidth: CGFloat = 2
    /// How wide the handle is to touch, centred on its line: the smallest comfortable target.
    static let touchWidth: CGFloat = 44
    /// How far past the knob the handle reaches, so that the knob is a target of `touchWidth`.
    static let touchPadding: CGFloat = (touchWidth - knobDiameter) / 2
    /// How far from the line a touch still counts as on it.
    static let stemTouchSlop: CGFloat = 4
    /// The line is never shorter than this, so that a handle on a line of very small text can be seen.
    static let minimumStem: CGFloat = 8

    let edge: Edge
    /// The handle at the other end, which a touch that both of them have room for goes to the nearer of.
    weak var sibling: SelectionHandleView?

    private let stemView = UIView()
    private let knobView = UIView()
    /// How long the line is, and how far the frame reaches past the line's end away from the knob, to
    /// make the knob a target of `touchWidth` all round when the line is short.
    private var stemLength: CGFloat = SelectionHandleView.minimumStem
    private var spare: CGFloat = 0

    init(edge: Edge) {
        self.edge = edge
        super.init(frame: .zero)
        backgroundColor = .clear
        for part in [stemView, knobView] {
            part.backgroundColor = .tintColor
            part.isUserInteractionEnabled = false
            addSubview(part)
        }
        knobView.layer.cornerRadius = Self.knobDiameter / 2
        isHidden = true
        // The identifiers are for UI tests; the labels are what VoiceOver says.
        isAccessibilityElement = true
        switch edge {
        case .start:
            accessibilityIdentifier = "selectionHandleStart"
            accessibilityLabel = Strings.selectionStart
        case .end:
            accessibilityIdentifier = "selectionHandleEnd"
            accessibilityLabel = Strings.selectionEnd
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Puts the handle where its line runs from `top` down to `bottom`, which are the two ends of the
    /// selected text's line at the handle's side of it, in the superview's coordinates. The knob is past
    /// `top` for the handle at the start of the selection and past `bottom` for the one at the end.
    func place(top: CGPoint, bottom: CGPoint) {
        let length = max(bottom.y - top.y, Self.minimumStem)
        // Past the line's end, away from the knob, the frame goes on for as far as the knob's target
        // does: further than the line when the line is short.
        let spare = max(Self.touchPadding - length, 0)
        let reach = Self.knobDiameter + Self.touchPadding
        let x = top.x - Self.touchWidth / 2
        let placed: CGRect
        switch edge {
        case .start:
            placed = CGRect(x: x, y: top.y - reach, width: Self.touchWidth, height: reach + length + spare)
        case .end:
            placed = CGRect(x: x, y: top.y - spare, width: Self.touchWidth, height: spare + length + reach)
        }
        let changed = length != stemLength || spare != self.spare
        stemLength = length
        self.spare = spare
        if frame != placed { frame = placed }
        if changed { setNeedsLayout() }
    }

    /// Whether `point` (the view's own coordinates) is the handle's: on the knob's disc or by the line,
    /// and, if the other handle has room for it too, nearer to this one.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard let mine = reach(of: point) else { return false }
        if let sibling, !sibling.isHidden, sibling.superview === superview,
           let theirs = sibling.reach(of: sibling.convert(point, from: self)), theirs < mine {
            return false
        }
        return true
    }

    /// How far `point` (the view's own coordinates) is from the drawn handle, the knob or the line,
    /// whichever is nearer; nil when it is farther than the handle takes touches from: `touchPadding`
    /// from the knob, `stemTouchSlop` from the line.
    private func reach(of point: CGPoint) -> CGFloat? {
        let knob = knobView.center
        let fromKnob = max(hypot(point.x - knob.x, point.y - knob.y) - Self.knobDiameter / 2, 0)
        let stem = stemView.frame
        let fromStem = hypot(max(stem.minX - point.x, 0, point.x - stem.maxX), max(stem.minY - point.y, 0, point.y - stem.maxY))
        guard fromKnob <= Self.touchPadding || fromStem <= Self.stemTouchSlop else { return nil }
        return min(fromKnob, fromStem)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let reach = Self.knobDiameter + Self.touchPadding
        let axis = bounds.midX
        switch edge {
        case .start:
            knobView.frame = CGRect(x: axis - Self.knobDiameter / 2, y: Self.touchPadding, width: Self.knobDiameter, height: Self.knobDiameter)
            stemView.frame = CGRect(x: axis - Self.stemWidth / 2, y: reach, width: Self.stemWidth, height: stemLength)
        case .end:
            stemView.frame = CGRect(x: axis - Self.stemWidth / 2, y: spare, width: Self.stemWidth, height: stemLength)
            knobView.frame = CGRect(x: axis - Self.knobDiameter / 2, y: spare + stemLength, width: Self.knobDiameter, height: Self.knobDiameter)
        }
    }

    /// The line, in the superview's coordinates. For tests.
    var stemFrame: CGRect {
        layoutIfNeeded()
        return stemView.convert(stemView.bounds, to: superview)
    }

    /// The knob, in the superview's coordinates. For tests.
    var knobFrame: CGRect {
        layoutIfNeeded()
        return knobView.convert(knobView.bounds, to: superview)
    }
}

/// The pan that drags a handle. It notes where the touch went down, in the coordinates of
/// `referenceView`: the pan only begins once the finger has moved a little, and where it is then is
/// not where the drag started, so measuring from there would lose the first stretch of it.
final class HandlePanGestureRecognizer: UIPanGestureRecognizer {
    /// The view the locations are in: the scroll view, which does not move with the finger.
    weak var referenceView: UIView?
    /// Where the touch went down, in `referenceView`'s coordinates.
    private(set) var initialLocation: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let referenceView {
            initialLocation = touch.location(in: referenceView)
        }
        super.touchesBegan(touches, with: event)
    }
}
