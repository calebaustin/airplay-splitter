import SwiftUI
import AppKit

/// Keeps the menu window's top edge on the menu bar.
///
/// SwiftUI resizes a MenuBarExtra window around its bottom edge, so when the
/// content gets shorter (a notice closing, say) the menu would drop away from
/// the bar. This moves it back up after every resize. It never resizes the
/// window itself: the page area has a fixed height, so switching pages
/// doesn't change the menu's size at all.
struct MenuAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
                observers.append(NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.pin() }
                })
            }
        }

        /// Top edge on the menu bar's bottom edge (or as close as the window
        /// was first placed, whichever is higher).
        private func pin() {
            guard let window, let screen = window.screen else { return }
            let top = screen.visibleFrame.maxY
            guard window.frame.maxY < top - 0.5 else { return }
            var f = window.frame
            f.origin.y = top - f.height
            window.setFrame(f, display: true)
        }
    }
}
