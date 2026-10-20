import UIKit

/// Keeps a view being typed in, over the pages in the scroll view (a text box's, a form field's), clear
/// of the keyboard: while it is up and the keyboard covers the bottom of the view, the scroll view's
/// bottom inset leaves room for the keyboard (beyond what the safe area already does) and `clearance`
/// more, for what stands over the pages above the keyboard (the palette, the page indicator), so the
/// pages can scroll the view clear of it, down to the end of the document; and the pages scroll so it
/// is. The inset is put back once nothing is typed in.
///
/// It listens to the keyboard coming, moving and going (`install`). Its owner tells it when the view
/// being typed in comes or goes (`editingDidChange`), and when it grows (`reveal`).
@MainActor
final class KeyboardAvoidance: NSObject {
    private weak var scrollView: UIScrollView?
    /// The view being typed in, a subview of the scroll view; nil while none is.
    private let editedView: @MainActor () -> UIView?
    /// How much more than the keyboard covers the bottom of the view has over it, in points.
    private let clearance: @MainActor () -> CGFloat
    /// The scroll view's bottom inset before the keyboard came up over a view being typed in, to put
    /// back when the view goes; nil while the keyboard has not moved it.
    private var insetBeforeKeyboard: CGFloat?
    /// How far the keyboard reaches up over the scroll view, in its points; 0 while it is down.
    private(set) var keyboardCover: CGFloat = 0

    init(scrollView: UIScrollView?, editedView: @escaping @MainActor () -> UIView?, clearance: @escaping @MainActor () -> CGFloat) {
        self.scrollView = scrollView
        self.editedView = editedView
        self.clearance = clearance
        super.init()
    }

    /// Listens to the keyboard coming, moving and going.
    func install() {
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                                               name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(keyboardWillHide(_:)),
                                               name: UIResponder.keyboardWillHideNotification, object: nil)
    }

    @objc private func keyboardWillChangeFrame(_ notification: Notification) {
        guard let scrollView, let window = scrollView.window,
              let end = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let keyboard = scrollView.convert(window.convert(end, from: window.screen.coordinateSpace), from: window)
        keyboardCover = max(0, scrollView.bounds.maxY - keyboard.minY)
        editingDidChange()
        reveal()
    }

    @objc private func keyboardWillHide(_ notification: Notification) {
        keyboardCover = 0
        editingDidChange()
    }

    /// The view being typed in came or went, or the keyboard moved: while one is typed in and the
    /// keyboard is up, the bottom inset leaves room for the keyboard; otherwise it is put back.
    func editingDidChange() {
        guard let scrollView else { return }
        if editedView() != nil, keyboardCover > 0 {
            let before = insetBeforeKeyboard ?? scrollView.contentInset.bottom
            insetBeforeKeyboard = before
            let wanted = max(before, keyboardCover + clearance() - scrollView.safeAreaInsets.bottom)
            if scrollView.contentInset.bottom != wanted { scrollView.contentInset.bottom = wanted }
        } else if let before = insetBeforeKeyboard {
            insetBeforeKeyboard = nil
            if scrollView.contentInset.bottom != before { scrollView.contentInset.bottom = before }
        }
    }

    /// Scrolls the pages, if need be, so the view being typed in is in the part of the view the bars and
    /// the keyboard leave: its bottom, where text grows, without scrolling its top out of view.
    func reveal() {
        guard let scrollView, let view = editedView(), view.window != nil else { return }
        let visible = scrollView.bounds.inset(by: scrollView.adjustedContentInset)
        let box = view.frame.insetBy(dx: -8, dy: -8)
        var offset = scrollView.contentOffset
        if box.maxY > visible.maxY {
            offset.y += max(0, min(box.maxY - visible.maxY, box.minY - visible.minY))
        } else if box.minY < visible.minY {
            offset.y -= visible.minY - box.minY
        }
        if box.maxX > visible.maxX {
            offset.x += max(0, min(box.maxX - visible.maxX, box.minX - visible.minX))
        } else if box.minX < visible.minX {
            offset.x -= visible.minX - box.minX
        }
        let insets = scrollView.adjustedContentInset
        let highest = CGPoint(x: max(-insets.left, scrollView.contentSize.width + insets.right - scrollView.bounds.width),
                              y: max(-insets.top, scrollView.contentSize.height + insets.bottom - scrollView.bounds.height))
        offset = CGPoint(x: min(max(offset.x, -insets.left), highest.x), y: min(max(offset.y, -insets.top), highest.y))
        if offset != scrollView.contentOffset { scrollView.setContentOffset(offset, animated: true) }
    }
}
