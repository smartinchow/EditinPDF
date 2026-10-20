import UIKit

/// The form's widgets on one page, over it, in reading mode: a button over each widget
/// (`FormWidgetButton`), tinted light blue when its field may be filled in. A tap on one fills it in
/// (`FormInteraction`); everywhere else the touch goes through to the page, which scrolls, zooms and
/// selects text as before.
///
/// It lies in the scroll view's content view beside its page's view, with the page's frame, so the zoom
/// scales it with the page; and not inside the page's view, whose picture of itself, shown while the
/// page is drawn again after a fill (`PageView.redraw`), would carry the tint twice. The widgets' boxes
/// are in view space (PDF points of the page as shown, its rotation applied), so a button is laid out
/// at its box times `bounds.width / pointSize.width`, as the page's own overlay draws its boxes.
final class FormOverlay: UIView {
    /// The page, counting from 0.
    let page: Int
    /// The page's size in PDF points, as shown: the units of the widgets' boxes.
    let pointSize: CGSize
    /// The buttons over the page's widgets, in the document's order.
    private(set) var buttons: [FormWidgetButton] = []

    init(page: Int, pointSize: CGSize) {
        self.page = page
        self.pointSize = pointSize
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Puts `buttons` over the page in place of those it had. A button it has already stays where it
    /// is, so a finger on it is not let go of.
    func show(_ buttons: [FormWidgetButton]) {
        let kept = Set(buttons.map(ObjectIdentifier.init))
        for button in self.buttons where !kept.contains(ObjectIdentifier(button)) { button.removeFromSuperview() }
        self.buttons = buttons
        for button in buttons where button.superview !== self { addSubview(button) }
        setNeedsLayout()
    }

    /// Layer points per PDF point; 0 while there is nothing to scale by.
    private var scale: CGFloat {
        guard pointSize.width > 0, pointSize.width.isFinite, bounds.width > 0 else { return 0 }
        return bounds.width / pointSize.width
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = scale
        for button in buttons {
            let box = button.box
            button.frame = CGRect(x: box.minX * scale, y: box.minY * scale, width: box.width * scale, height: box.height * scale)
        }
    }

    /// A touch on a widget is its button's; anywhere else it goes through to the page under it.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// The button over one widget of a form field: a tap fills the field in, or, for a drop-down list,
/// opens its menu. For VoiceOver and the UI tests it is the widget: identified as
/// `formField-<name>-<widget>`, named for its field, holding the field's value.
final class FormWidgetButton: UIButton {
    /// Where it is in `FormIndex.fields`.
    let spot: FormIndex.Spot
    /// The field's full name.
    let field: String
    /// The widget's box, in view space.
    let box: CGRect
    /// Whether a tap opens its menu (a drop-down list that may be filled in) rather than acting.
    let opensMenu: Bool

    init(spot: FormIndex.Spot, field: String, box: CGRect, opensMenu: Bool) {
        self.spot = spot
        self.field = field
        self.box = box
        self.opensMenu = opensMenu
        super.init(frame: .zero)
        accessibilityIdentifier = "formField-\(field)-\(spot.widget)"
    }

    /// Whether it is the button a widget at `spot` of `field`, at `box`, needs: the same widget, in the
    /// same place, acting the same way.
    func isSame(spot: FormIndex.Spot, field: String, box: CGRect, opensMenu: Bool) -> Bool {
        self.spot == spot && self.field == field && self.box == box && self.opensMenu == opensMenu
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// Whether a box is one a button can lie on: finite, and not empty.
    nonisolated static func isUsable(_ box: CGRect) -> Bool {
        [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite) && box.width > 0 && box.height > 0
    }
}
