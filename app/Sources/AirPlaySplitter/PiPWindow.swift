import AppKit
import ScreenCaptureKit
import ApplicationServices

/// A live, clickable picture-in-picture of the Extended Screen, so you can
/// work on it from your MacBook without moving the pointer over to a screen
/// you can't see. It captures the screen directly on this Mac (no TV delay).
///
/// Clicks, drags, right-clicks and scrolling in the window are sent to the
/// same spot on the extended screen, then the pointer comes straight back.
/// Typing just works: whatever you clicked there has the keyboard. Sending
/// clicks needs Accessibility permission; without it the window only shows.
@MainActor
final class PiPController: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var view: PiPView?
    private var stream: SCStream?
    private var output: FrameOutput?
    private var displayID: CGDirectDisplayID = 0
    var onClose: (() -> Void)?

    var isOpen: Bool { panel?.isVisible == true }

    func toggle(displayID id: CGDirectDisplayID) {
        isOpen ? close() : open(displayID: id)
    }

    func open(displayID id: CGDirectDisplayID) {
        displayID = id
        if panel == nil { makePanel() }
        view?.displayID = id
        panel?.orderFrontRegardless()
        Task { await startCapture() }
        // Ask once for Accessibility so clicks can reach the extended screen.
        if !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        }
    }

    func close() {
        panel?.orderOut(nil)
        stopCapture()
        onClose?()
    }

    func windowWillClose(_ notification: Notification) {
        stopCapture()
        onClose?()
    }

    private func makePanel() {
        let size = CGSize(width: 640, height: 360)
        let screen = NSScreen.main?.visibleFrame ?? .zero
        let frame = CGRect(x: screen.maxX - size.width - 24, y: screen.minY + 24, width: size.width, height: size.height)
        let p = NSPanel(contentRect: frame,
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.title = "Extended Screen"
        p.titlebarAppearsTransparent = true
        p.titleVisibility = .hidden
        p.isMovableByWindowBackground = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentAspectRatio = CGSize(width: 16, height: 9)
        p.minSize = CGSize(width: 320, height: 180)
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        p.backgroundColor = .black
        p.delegate = self
        let v = PiPView(frame: CGRect(origin: .zero, size: size))
        v.autoresizingMask = [.width, .height]
        p.contentView = v
        panel = p
        view = v
    }

    private func startCapture() async {
        stopCapture()
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return }
        let cfg = SCStreamConfiguration()
        cfg.width = display.width
        cfg.height = display.height
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: 60)
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.queueDepth = 3
        cfg.showsCursor = true
        let out = FrameOutput { [weak self] surface in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.view?.show(surface) } }
        }
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: nil)
        do {
            try s.addStreamOutput(out, type: .screen, sampleHandlerQueue: DispatchQueue(label: "pip.frames"))
            try await s.startCapture()
            stream = s
            output = out
        } catch {
            NSLog("AirPlaySplitter PiP capture failed: %@", error.localizedDescription)
        }
    }

    private func stopCapture() {
        if let s = stream { Task { try? await s.stopCapture() } }
        stream = nil
        output = nil
    }
}

/// Hands each captured frame's IOSurface to the window.
private final class FrameOutput: NSObject, SCStreamOutput {
    let onFrame: (IOSurface) -> Void
    init(onFrame: @escaping (IOSurface) -> Void) { self.onFrame = onFrame }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pb = CMSampleBufferGetImageBuffer(sb),
              let surface = CVPixelBufferGetIOSurface(pb)?.takeUnretainedValue() else { return }
        onFrame(surface as IOSurface)
    }
}

/// Shows the frames and forwards the mouse to the extended screen.
final class PiPView: NSView {
    var displayID: CGDirectDisplayID = 0
    private var returnTo: CGPoint?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .linear
    }
    required init?(coder: NSCoder) { fatalError() }

    func show(_ surface: IOSurface) { layer?.contents = surface }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

    // MARK: forwarding

    override func mouseDown(with e: NSEvent) { send(.leftMouseDown, e, button: .left) }
    override func mouseDragged(with e: NSEvent) { send(.leftMouseDragged, e, button: .left) }
    override func mouseUp(with e: NSEvent) { send(.leftMouseUp, e, button: .left, done: true) }
    override func rightMouseDown(with e: NSEvent) { send(.rightMouseDown, e, button: .right) }
    override func rightMouseUp(with e: NSEvent) { send(.rightMouseUp, e, button: .right, done: true) }

    override func scrollWheel(with e: NSEvent) {
        guard let target = map(e), let ev = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                                                    wheel1: Int32(e.scrollingDeltaY), wheel2: Int32(e.scrollingDeltaX), wheel3: 0)
        else { return }
        let back = currentPointer()
        CGWarpMouseCursorPosition(target)
        ev.location = target
        ev.post(tap: .cghidEventTap)
        CGWarpMouseCursorPosition(back)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    /// Posts the event at the matching point on the extended screen, then puts
    /// the pointer back over this window so you never lose it.
    private func send(_ type: CGEventType, _ e: NSEvent, button: CGMouseButton, done: Bool = false) {
        guard AXIsProcessTrusted() else { return }
        guard let target = map(e) else { return }
        if returnTo == nil { returnTo = currentPointer() }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: target, mouseButton: button)
        else { return }
        ev.setIntegerValueField(.mouseEventClickState, value: Int64(max(1, e.clickCount)))
        ev.post(tap: .cghidEventTap)
        // Back over the window, so the next movement starts from here.
        CGWarpMouseCursorPosition(currentPointerFor(e))
        CGAssociateMouseAndMouseCursorPosition(1)
        if done { returnTo = nil }
    }

    /// The point on the extended screen (global, top-left origin) under the
    /// mouse, or nil outside the picture (the black bars).
    private func map(_ e: NSEvent) -> CGPoint? {
        let p = convert(e.locationInWindow, from: nil)
        let disp = CGDisplayBounds(displayID)
        guard disp.width > 0, bounds.width > 0 else { return nil }
        // The picture is aspect-fit inside the view.
        let scale = min(bounds.width / disp.width, bounds.height / disp.height)
        let w = disp.width * scale, h = disp.height * scale
        let x0 = (bounds.width - w) / 2, y0 = (bounds.height - h) / 2
        let u = (p.x - x0) / w, v = (p.y - y0) / h   // v from the bottom
        guard (0...1).contains(u), (0...1).contains(v) else { return nil }
        return CGPoint(x: disp.minX + u * disp.width, y: disp.minY + (1 - v) * disp.height)
    }

    /// Where the event happened, in global top-left coordinates.
    private func currentPointerFor(_ e: NSEvent) -> CGPoint {
        guard let w = window else { return currentPointer() }
        let screenPoint = w.convertPoint(toScreen: e.locationInWindow)
        return Self.flip(screenPoint)
    }

    private func currentPointer() -> CGPoint { Self.flip(NSEvent.mouseLocation) }

    /// AppKit (bottom-left origin) to Quartz (top-left origin) coordinates.
    private static func flip(_ p: NSPoint) -> CGPoint {
        let h = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: p.x, y: h - p.y)
    }
}
