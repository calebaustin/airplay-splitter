import SwiftUI
import AppKit

/// Follows a two-finger trackpad swipe over this view, so the pages can slide
/// under the fingers like a row of panels that was already there.
///
/// `onDrag` reports how far the fingers have moved sideways (points, in the
/// direction the content should move); `onEnd` reports the final distance and
/// the speed at release so the caller can settle on a page. Mostly-vertical
/// scrolling is left alone, so lists inside still scroll normally. A mouse's
/// sideways wheel (no gesture phases) turns one page per nudge via `onStep`.
struct HorizontalSwipe: NSViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: (_ distance: CGFloat, _ velocity: CGFloat) -> Void
    /// -1 = previous page, +1 = next.
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> SwipeView {
        let v = SwipeView()
        update(v)
        return v
    }
    func updateNSView(_ v: SwipeView, context: Context) { update(v) }

    private func update(_ v: SwipeView) {
        v.onDrag = onDrag; v.onEnd = onEnd; v.onStep = onStep
    }

    final class SwipeView: NSView {
        var onDrag: ((CGFloat) -> Void)?
        var onEnd: ((CGFloat, CGFloat) -> Void)?
        var onStep: ((Int) -> Void)?

        private enum Lock { case undecided, sideways, vertical, ignored }
        private var monitor: Any?
        private var lock = Lock.ignored
        private var dx: CGFloat = 0
        private var dy: CGFloat = 0
        private var velocity: CGFloat = 0
        private var lastTime: TimeInterval = 0
        private var wheelDX: CGFloat = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }   // never steals clicks

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self else { return e }
                // Once a swipe is ours, keep it from also nudging lists inside.
                return self.handle(e) ? nil : e
            }
        }

        /// Returns true when the event was used for paging.
        private func handle(_ e: NSEvent) -> Bool {
            guard let window, e.window === window else { return false }
            let p = convert(e.locationInWindow, from: nil)

            // Mouse wheel: no phases at all.
            if e.phase == [] && e.momentumPhase == [] {
                guard bounds.contains(p) else { wheelDX = 0; return false }
                wheelDX += e.scrollingDeltaX
                if abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY), abs(wheelDX) >= 30 {
                    onStep?(wheelDX < 0 ? 1 : -1)
                    wheelDX = 0
                    return true
                }
                return false
            }

            // Momentum after lifting the fingers: swallow it if the swipe was
            // ours (the page is already settling), otherwise pass it on.
            if e.momentumPhase != [] { return lock == .sideways }

            if e.phase == .began || e.phase == .mayBegin {
                lock = bounds.contains(p) ? .undecided : .ignored
                dx = 0; dy = 0; velocity = 0; lastTime = e.timestamp
            }
            guard lock != .ignored, lock != .vertical else { return false }

            let ddx = e.scrollingDeltaX
            dx += ddx
            dy += e.scrollingDeltaY
            let dt = max(e.timestamp - lastTime, 1.0 / 240)
            lastTime = e.timestamp
            if ddx != 0 { velocity = velocity * 0.6 + (ddx / CGFloat(dt)) * 0.4 }

            if lock == .undecided, hypot(dx, dy) > 6 {
                lock = abs(dx) > abs(dy) * 1.2 ? .sideways : .vertical
            }

            if e.phase == .ended || e.phase == .cancelled {
                let was = lock
                lock = was == .sideways ? .sideways : .ignored   // keep for momentum
                if was == .sideways { onEnd?(dx, velocity); return true }
                return false
            }

            if lock == .sideways { onDrag?(dx); return true }
            return false
        }

        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
