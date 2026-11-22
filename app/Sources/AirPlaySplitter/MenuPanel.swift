import SwiftUI
import AppKit
import Combine
import ScreenCaptureKit

/// The menu bar icon and the panel it opens, built like Control Center (and
/// Church Studio's menu bar panel): a borderless, fully transparent window
/// placed just under the menu bar, so only the glass tiles show over the
/// desktop. Because we place the window ourselves, its top edge always sits
/// on the menu bar however its contents change.
@MainActor
final class MenuPanelController: NSObject {
    private let model: SplitterModel
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let panel: MenuPanel
    private let host: PinnedHostingView<MenuRoot>
    private let badge = NSView()
    private var monitors: [Any] = []
    private var bag: Set<AnyCancellable> = []
    private var opens = 0
    private static weak var current: MenuPanelController?

    /// Closes the menu before something else needs the screen (an area
    /// picker, a file dialog), the way a system menu would.
    static func hideMenu() { current?.hide() }

    init(model: SplitterModel) {
        self.model = model
        host = PinnedHostingView(rootView: MenuRoot(model: model, opening: 0))
        host.sizingOptions = [.intrinsicContentSize]
        panel = MenuPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        Self.current = self

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false               // each tile draws its own depth
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.contentView = host
        host.onResize = { [weak self] in self?.place() }

        if let button = item.button {
            button.image = MenuBarIcon.templateImage
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(toggle)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityLabel("AirPlay Splitter")
            badge.wantsLayer = true
            badge.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            badge.layer?.cornerRadius = 2.5
            badge.frame = CGRect(x: 0, y: 0, width: 5, height: 5)
            badge.isHidden = true
            button.addSubview(badge)
        }
        // Dim the icon while nothing is being sent; a dot when an update is out.
        model.$selected.combineLatest(model.$update)
            .receive(on: RunLoop.main)
            .sink { [weak self] selected, update in self?.refreshIcon(active: !selected.isEmpty, badge: update != nil) }
            .store(in: &bag)
    }

    private func refreshIcon(active: Bool, badge on: Bool) {
        guard let button = item.button else { return }
        button.appearsDisabled = !active && !on
        badge.isHidden = !on
        let b = button.bounds
        badge.frame.origin = CGPoint(x: b.midX + 6, y: b.maxY - 8)
    }

    @objc private func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show() {
        opens += 1
        // A fresh view each time so the tiles settle in again.
        host.rootView = MenuRoot(model: model, opening: opens)
        model.previewVisible = true
        host.layoutSubtreeIfNeeded()
        place()
        panel.orderFrontRegardless()
        panel.makeKey()
        // Don't drop the cursor into the first text field on open.
        DispatchQueue.main.async { [weak self] in self?.panel.makeFirstResponder(nil) }
        item.button?.highlight(true)
        watchForDismiss()
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.previewVisible = false
        item.button?.highlight(false)
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
    }

    /// Developer check: saves a screenshot of the open panel with the
    /// desktop behind it (uses the app's own Screen Recording permission).
    func snapshot(to path: String) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let screen = panel.screen,
              let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let display = content.displays.first(where: { $0.displayID == id.uint32Value }) else { print("no display"); return }
        let f = panel.frame.insetBy(dx: -20, dy: -20)
        let flipped = CGRect(x: f.minX - screen.frame.minX, y: screen.frame.maxY - f.maxY, width: f.width, height: f.height)
        let cfg = SCStreamConfiguration()
        cfg.sourceRect = flipped
        cfg.width = Int(flipped.width * screen.backingScaleFactor)
        cfg.height = Int(flipped.height * screen.backingScaleFactor)
        cfg.showsCursor = false
        let filter = SCContentFilter(display: display, excludingWindows: [])
        do {
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
            print("saved \(path)")
        } catch { print("snapshot failed: \(error)") }
    }

    /// Top edge just under the menu bar, centred on the icon, kept on screen.
    private func place() {
        guard let button = item.button, let bw = button.window else { return }
        let size = host.fittingSize
        let iconFrame = bw.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = bw.screen ?? NSScreen.main
        let area = screen?.visibleFrame ?? .zero
        var x = iconFrame.midX - size.width / 2
        x = min(max(x, area.minX + 8), area.maxX - size.width - 8)
        let top = area.maxY - 4
        panel.setFrame(CGRect(x: x, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    /// Closes on a click anywhere else or on Escape, like a system menu.
    private func watchForDismiss() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] e in
            if e.keyCode == 53, e.window === self?.panel { MainActor.assumeIsolated { self?.hide() }; return nil }
            return e
        }) { monitors.append(m) }
    }
}

/// A panel that can take typing (PIN, place names) without activating the app.
final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Reports size changes so the panel can grow and shrink downward only.
final class PinnedHostingView<V: View>: NSHostingView<V> {
    var onResize: (() -> Void)?
    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onResize?() }
    }
}

/// Rebuilt on every open (new `opening`), so entrance motion replays and the
/// page you were on is remembered.
struct MenuRoot: View {
    let model: SplitterModel
    let opening: Int
    var body: some View {
        SplitterMenu(model: model, page: SplitterMenu.lastPage)
            .id(opening)
    }
}
