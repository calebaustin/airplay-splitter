import SwiftUI
import AppKit

/// Keeps the menu window's top edge on the menu bar.
///
/// SwiftUI resizes a MenuBarExtra window around its bottom edge, so when the
/// content gets shorter (say, while Refresh looks for TVs) the whole menu
/// drops away from the bar. This watches the window and moves it back up
/// after every resize, so it always grows and shrinks downward.
struct MenuAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {}

    final class AnchorView: NSView {
        private var observer: NSObjectProtocol?
        private var top: CGFloat?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            guard let window else { return }
            top = window.frame.maxY
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pin() }
            }
        }

        private func pin() {
            guard let window, let screen = window.screen else { return }
            // The menu bar's bottom edge, or the first top edge seen.
            let barBottom = screen.visibleFrame.maxY
            let target = min(top ?? barBottom, barBottom)
            guard abs(window.frame.maxY - target) > 0.5 else { return }
            var f = window.frame
            f.origin.y = target - f.height
            window.setFrame(f, display: true)
        }
    }
}
