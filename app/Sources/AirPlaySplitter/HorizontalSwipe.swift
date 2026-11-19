import SwiftUI
import AppKit

/// Turns a two-finger trackpad swipe (or a sideways mouse scroll) over this
/// view into one "next" or "previous" call per gesture. Mostly-vertical
/// scrolling is left alone, so lists inside still scroll normally.
struct HorizontalSwipe: NSViewRepresentable {
    /// -1 = swiped toward the previous page, +1 = toward the next.
    let onSwipe: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        let v = SwipeView()
        v.onSwipe = onSwipe
        return v
    }
    func updateNSView(_ v: SwipeView, context: Context) { v.onSwipe = onSwipe }

    final class SwipeView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0
        private var fired = false
        private static let threshold: CGFloat = 45

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steals clicks

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                self?.handle(e)
                return e
            }
        }

        private func handle(_ e: NSEvent) {
            guard let window, e.window === window, e.momentumPhase == [] else { return }
            // Only gestures that start over this section count.
            let p = convert(e.locationInWindow, from: nil)
            if e.phase == .began {
                guard bounds.contains(p) else { fired = true; return }
                dx = 0; dy = 0; fired = false
            }
            guard !fired else { return }
            dx += e.scrollingDeltaX
            dy += e.scrollingDeltaY
            // Mouse wheels have no phase: treat each sideways tick as a nudge.
            let sideways = abs(dx) > abs(dy) * 1.5
            if sideways, abs(dx) >= Self.threshold {
                fired = true
                // Natural scrolling: fingers moving left (negative dx) go forward.
                onSwipe?(dx < 0 ? 1 : -1)
            }
            if e.phase == .ended || e.phase == .cancelled { dx = 0; dy = 0 }
            if e.phase == [] && !bounds.contains(p) { dx = 0; dy = 0 }
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
