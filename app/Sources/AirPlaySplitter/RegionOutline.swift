import AppKit

/// A dashed outline around the shared part of a screen, as a reminder of what
/// the TVs show. It sits just outside the area (so it's never in the picture),
/// ignores the mouse, and follows you across Spaces.
@MainActor
final class RegionOutline {
    private var window: NSWindow?
    private var view: OutlineView?
    private static let margin: CGFloat = 4      // gap between the area and the line
    private static let labelRoom: CGFloat = 26  // space above for the "Sharing" tag

    /// - rect: the area in the display's points, top-left origin.
    func show(_ rect: CGRect, on screen: NSScreen, live: Bool) {
        // Convert to global, bottom-left coordinates, then grow to hold the line.
        let global = CGRect(x: screen.frame.minX + rect.minX,
                            y: screen.frame.maxY - rect.maxY,
                            width: rect.width, height: rect.height)
        let room = global.maxY + Self.labelRoom <= screen.frame.maxY ? Self.labelRoom : 0
        let frame = global.insetBy(dx: -Self.margin - 2, dy: -Self.margin - 2)
            .union(CGRect(x: global.minX, y: global.maxY, width: 1, height: room))

        if window == nil {
            let w = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.hasShadow = false
            w.ignoresMouseEvents = true
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            w.sharingType = .none      // keep it out of any screen capture
            let v = OutlineView(frame: CGRect(origin: .zero, size: frame.size))
            w.contentView = v
            window = w
            view = v
        }
        window?.setFrame(frame, display: true)
        view?.area = CGRect(x: global.minX - frame.minX, y: global.minY - frame.minY,
                            width: global.width, height: global.height)
        view?.showLabel = room > 0
        view?.live = live
        view?.frame = CGRect(origin: .zero, size: frame.size)
        view?.needsDisplay = true
        window?.orderFrontRegardless()
    }

    func hide() {
        window?.orderOut(nil)
    }

    private final class OutlineView: NSView {
        var area: CGRect = .zero
        var showLabel = true
        var live = false

        override func draw(_ dirty: NSRect) {
            let r = area.insetBy(dx: -RegionOutline.margin, dy: -RegionOutline.margin)
            let path = NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3)
            path.lineWidth = 2
            // A soft dark line under a dashed accent line reads on any background.
            NSColor.black.withAlphaComponent(0.35).setStroke()
            path.stroke()
            path.setLineDash([7, 5], count: 2, phase: 0)
            NSColor.controlAccentColor.withAlphaComponent(live ? 1 : 0.55).setStroke()
            path.stroke()

            guard showLabel else { return }
            let text = (live ? "Sharing this area" : "Selected area") as NSString
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                                                        .foregroundColor: NSColor.white]
            let size = text.size(withAttributes: attrs)
            let pill = CGRect(x: r.minX, y: r.maxY + 4, width: size.width + 16, height: size.height + 6)
            NSColor.controlAccentColor.withAlphaComponent(live ? 0.95 : 0.6).setFill()
            NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
            text.draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: attrs)
        }
    }
}
