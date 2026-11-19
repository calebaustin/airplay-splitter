import AppKit

/// Lets the user drag out part of a screen to share, like ⇧⌘4.
/// Calls back with the rectangle in that display's points (top-left origin,
/// as ScreenCaptureKit's sourceRect expects), or nil if cancelled with Esc.
@MainActor
final class RegionSelector {
    private var window: NSWindow?
    private var completion: ((CGRect?) -> Void)?

    func select(on screen: NSScreen, completion: @escaping (CGRect?) -> Void) {
        self.completion = completion
        let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
        view.onFinish = { [weak self] rect in self?.finish(rect, screen: screen) }
        let w = KeyWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        w.level = .screenSaver
        w.isOpaque = false
        w.backgroundColor = .clear
        w.ignoresMouseEvents = false
        w.contentView = view
        w.setFrame(screen.frame, display: true)
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        w.makeFirstResponder(view)
        NSCursor.crosshair.push()
        window = w
    }

    private func finish(_ rect: CGRect?, screen: NSScreen) {
        NSCursor.pop()
        window?.orderOut(nil)
        window = nil
        // View coordinates are bottom-left; ScreenCaptureKit wants top-left.
        let flipped = rect.map { CGRect(x: $0.minX, y: screen.frame.height - $0.maxY,
                                        width: $0.width, height: $0.height).integral }
        completion?(flipped)
        completion = nil
    }

    private final class KeyWindow: NSWindow {
        override var canBecomeKey: Bool { true }
    }

    private final class SelectionView: NSView {
        var onFinish: ((CGRect?) -> Void)?
        private var start: CGPoint?
        private var current: CGRect?

        override var acceptsFirstResponder: Bool { true }

        override func draw(_ dirty: NSRect) {
            NSColor.black.withAlphaComponent(0.35).setFill()
            bounds.fill()
            if let r = current {
                NSGraphicsContext.current?.compositingOperation = .clear
                r.fill()
                NSGraphicsContext.current?.compositingOperation = .sourceOver
                NSColor.white.setStroke()
                let border = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
                border.lineWidth = 1
                border.stroke()
                let label = "\(Int(r.width)) × \(Int(r.height))" as NSString
                label.draw(at: CGPoint(x: r.minX + 6, y: r.minY - 20),
                           withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium),
                                            .foregroundColor: NSColor.white])
            } else {
                let hint = "Drag to choose the part of the screen to share. Press Esc to cancel." as NSString
                let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 18, weight: .medium),
                                                            .foregroundColor: NSColor.white]
                let size = hint.size(withAttributes: attrs)
                hint.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY), withAttributes: attrs)
            }
        }

        override func mouseDown(with e: NSEvent) { start = convert(e.locationInWindow, from: nil) }

        override func mouseDragged(with e: NSEvent) {
            guard let start else { return }
            let p = convert(e.locationInWindow, from: nil)
            current = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                             width: abs(p.x - start.x), height: abs(p.y - start.y))
            needsDisplay = true
        }

        override func mouseUp(with e: NSEvent) {
            if let r = current, r.width >= 64, r.height >= 36 { onFinish?(r) } else { current = nil; needsDisplay = true }
        }

        override func keyDown(with e: NSEvent) {
            if e.keyCode == 53 { onFinish?(nil) } else { super.keyDown(with: e) }   // Esc
        }
    }
}
