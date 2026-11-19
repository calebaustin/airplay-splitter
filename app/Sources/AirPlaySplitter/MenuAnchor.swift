import SwiftUI
import AppKit

/// Keeps the menu window hanging from the menu bar and sized to its content.
///
/// A MenuBarExtra window doesn't always resize when its content changes after
/// it opens (switching pages with a swipe, for example), which left content
/// clipped at the top and bottom. And when it does resize, it does so around
/// its bottom edge, so the menu drifted away from the bar. On every content
/// update this measures the content, sets the window to that height (capped
/// to the screen) and puts its top edge back on the menu bar.
struct MenuAnchor: NSViewRepresentable {
    /// Anything that changes the menu's height; a change triggers a refit.
    var trigger: AnyHashable = 0

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        DispatchQueue.main.async { view.fit() }
    }

    final class AnchorView: NSView {
        private var observer: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didResizeNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pin() }
            }
            DispatchQueue.main.async { self.fit() }
        }

        /// Resize to the content's height, then pin the top to the bar.
        func fit() {
            guard let window, let content = window.contentView, let screen = window.screen else { return }
            let wanted = min(content.fittingSize.height, screen.visibleFrame.height - 8)
            if wanted > 0, abs(window.frame.height - wanted) > 0.5 {
                var f = window.frame
                f.size.height = wanted
                window.setFrame(f, display: true)
            }
            pin()
        }

        private func pin() {
            guard let window, let screen = window.screen else { return }
            let top = screen.visibleFrame.maxY   // the menu bar's bottom edge
            guard abs(window.frame.maxY - top) > 0.5 else { return }
            var f = window.frame
            f.origin.y = top - f.height
            window.setFrame(f, display: true)
        }
    }
}
