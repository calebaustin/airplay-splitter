import Foundation
import ScreenCaptureKit
import AppKit

@MainActor
final class SplitterModel: ObservableObject {
    enum Source: Hashable {
        case display(CGDirectDisplayID)
        case region(CGDirectDisplayID)   // part of a display; rect in `region`
        case window                      // chosen with the system sharing picker
        case phones                      // iPhone/iPad mirroring to "AirPlay Splitter" (UxPlay)
        case testPattern                 // moving test card; needs no permission
    }

    /// Whether the Mac's sound goes to the TVs. Off by default, so a room's
    /// own speakers don't double up; remembered between launches.
    @Published var sendAudio = UserDefaults.standard.bool(forKey: "sendAudio") {
        didSet {
            UserDefaults.standard.set(sendAudio, forKey: "sendAudio")
            streamer.setAudio(sendAudio)
            if source == .phones, uxplay != nil { uxplay?.terminate(); uxplay = nil; startUxPlay(); updateCapture() }
        }
    }

    /// Small live image of what's being sent (while the menu is open).
    @Published var preview: CGImage?
    var previewVisible = false { didSet { streamer.previewEnabled = previewVisible } }

    /// The part of the screen chosen for `.region`, in display points.
    private(set) var region: CGRect?
    /// The window chosen for `.window`, and a name for it.
    private var windowFilter: SCContentFilter?
    @Published private(set) var windowName: String?
    private let regionSelector = RegionSelector()
    private var pickerObserver: PickerObserver?

    /// Screen Recording permission. macOS only applies a new grant after the
    /// app restarts, so this is read once at launch.
    @Published var hasScreenAccess = CGPreflightScreenCaptureAccess()

    /// doubletake runs gst-launch-1.0 from Homebrew; others installing the
    /// DMG may not have it yet.
    let gstreamerMissing = SplitterModel.bundledGStreamer == nil &&
        !["/opt/homebrew/bin/gst-launch-1.0", "/usr/local/bin/gst-launch-1.0"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }

    var needsScreenAccess: Bool {
        switch source {
        case .display, .region: return !hasScreenAccess
        default: return false   // the window picker grants its own access
        }
    }

    var sourceName: String {
        switch source {
        case .display(let id): displays.first { $0.id == id }?.name.components(separatedBy: " (").first ?? "Screen"
        case .region(let id):
            "Part of \(displays.first { $0.id == id }?.name.components(separatedBy: " (").first ?? "screen")"
        case .window: windowName ?? "A window"
        case .phones: "iPhone or iPad"
        case .testPattern: "Test pattern"
        }
    }

    /// Sound can come from the Mac (screen, region, window) or the phone.
    var audioAvailable: Bool { source != .testPattern }

    var liveCount: Int { streams.values.filter { $0.state == "streaming" && selected.contains($0.device_ip) }.count }

    var summary: String {
        if selected.isEmpty { return "Not sending" }
        let n = liveCount
        if n == 0 { return "Connecting" }
        return n == 1 ? "Showing on 1 TV" : "Showing on \(n) TVs"
    }

    var sourceSymbol: String {
        switch source {
        case .display: "display"
        case .region: "rectangle.dashed"
        case .window: "macwindow"
        case .phones: "iphone"
        case .testPattern: "square.grid.3x3.topleft.filled"
        }
    }

    struct DisplayChoice: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
    }

    @Published var tvs: [DaemonClient.Device] = []
    @Published var streams: [String: DaemonClient.Stream] = [:]   // by IP
    @Published var selected: Set<String> = []                      // IPs the user ticked
    @Published var displays: [DisplayChoice] = []
    @Published var source: Source = .display(CGMainDisplayID()) { didSet { sourceChanged(from: oldValue) } }
    @Published var pinFor: DaemonClient.Device?
    @Published var message: String?

    static let rtpPort: UInt16 = 5600
    static let audioPort: UInt16 = 5602
    static let receiverName = "AirPlay Splitter"

    private let stateDir: URL
    private let client: DaemonClient
    private var daemon: Process?
    private var uxplay: Process?
    private let streamer = ScreenStreamer(rtpPort: rtpPort, audioPort: audioPort)
    private var capturing = false
    private var poll: Timer?
    private let discovery = Discovery()

    /// `preview` skips the daemon and network so the menu can be rendered
    /// with sample data (`--render-menu`).
    init(preview: Bool = false) {
        stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirPlaySplitter", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        client = DaemonClient(socketPath: stateDir.appendingPathComponent("dt.sock").path)
        if preview { return }
        streamer.onPreview = { [weak self] img in
            DispatchQueue.main.async { self?.preview = img }
        }
        startDaemon()
        discovery.onChange = { [weak self] list in
            // NetService delivers on the main run loop.
            MainActor.assumeIsolated {
                let me = Host.current().localizedName ?? ""
                self?.tvs = list
                    .filter { $0.name != Self.receiverName && $0.name != me }
                    .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }
        }
        discovery.start()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        Task { await loadDisplays() }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    // MARK: user actions

    func toggle(_ tv: DaemonClient.Device) {
        if selected.contains(tv.ip) {
            selected.remove(tv.ip)
            if pinFor?.ip == tv.ip { pinFor = nil }
            _ = try? client.send(["cmd": "disconnect", "target": tv.ip])
        } else {
            selected.insert(tv.ip)
            ensureSource()
            connect(tv, pin: nil)
        }
        updateCapture()
    }

    func submitPIN(_ pin: String) {
        guard let tv = pinFor else { return }
        pinFor = nil
        connect(tv, pin: pin.trimmingCharacters(in: .whitespaces))
    }

    func stopAll() {
        _ = try? client.send(["cmd": "disconnect"])
        selected.removeAll()
        updateCapture()
    }

    func shutdown() {
        _ = try? client.send(["cmd": "disconnect"])
        streamer.stop()
        uxplay?.terminate()
        daemon?.interrupt()
        daemon?.waitUntilExit()
    }

    /// Lists screens from AppKit, which needs no Screen Recording permission
    /// (asking ScreenCaptureKit here re-triggered the permission prompt).
    func loadDisplays() async {
        displays = NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let size = s.frame.size
            return DisplayChoice(id: n.uint32Value, name: "\(s.localizedName) (\(Int(size.width))×\(Int(size.height)))")
        }
    }

    /// Asks macOS once and opens the Screen Recording settings page.
    func requestScreenAccess() {
        if !CGRequestScreenCaptureAccess(),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// A Screen Recording grant only takes effect in a fresh process.
    func relaunch() {
        let path = Bundle.main.bundlePath
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n \"$0\"", path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: daemon

    private func connect(_ tv: DaemonClient.Device, pin: String?) {
        var req: [String: Any] = ["cmd": "connect", "target": tv.ip, "port": tv.port]
        if !tv.device_id.isEmpty { req["device_id"] = tv.device_id }
        if let pin { req["pin"] = pin }
        DispatchQueue.global().async { [client] in
            let r = try? client.send(req)
            Task { @MainActor in
                if r?.needs_pin == true || r?.needs_credential == true || r?.state == "pin_required" {
                    self.pinFor = tv
                } else if let e = r?.error, !e.isEmpty {
                    self.message = "\(tv.name): \(e)"
                }
            }
        }
    }

    private func refresh() {
        DispatchQueue.global().async { [client] in
            let status = try? client.send(["cmd": "status"])
            Task { @MainActor in
                var byIP: [String: DaemonClient.Stream] = [:]
                for s in status?.streams ?? [] { byIP[s.device_ip] = s }
                self.streams = byIP
                if let pending = byIP.values.first(where: { $0.state == "pin_required" }),
                   self.pinFor == nil, let tv = self.tvs.first(where: { $0.ip == pending.device_ip }) {
                    self.pinFor = tv
                }
            }
        }
    }

    private func startDaemon() {
        guard let bin = tool("doubletake") else {
            message = "doubletake binary not found"; return
        }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["-daemonize", "-relay-port", String(Self.rtpPort),
                       "-relay-audio-port", String(Self.audioPort),
                       "-socket", client.socketPath, "-port-range", "60000-60020"]
        p.environment = toolEnvironment()
        let log = stateDir.appendingPathComponent("doubletake.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: log)
        p.standardError = p.standardOutput
        do { try p.run(); daemon = p } catch { message = "Could not start doubletake: \(error.localizedDescription)" }
    }

    // MARK: sources

    private func ensureSource() {
        if case .phones = source, uxplay == nil { startUxPlay() }
    }

    // MARK: choosing what to show

    func chooseDisplay(_ id: CGDirectDisplayID) { source = .display(id) }
    func chooseTestPattern() { source = .testPattern }
    func choosePhones() { source = .phones }

    /// Drag out part of a screen. Keeps the current source if cancelled.
    func chooseRegion(on id: CGDirectDisplayID) {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) else { return }
        regionSelector.select(on: screen) { [weak self] rect in
            guard let self, let rect else { return }
            self.region = rect
            if self.source == .region(id) { self.restartCapture() } else { self.source = .region(id) }
        }
    }

    /// Opens macOS's own window picker (the one FaceTime and Zoom use).
    func chooseWindow() {
        let picker = SCContentSharingPicker.shared
        if pickerObserver == nil {
            let o = PickerObserver { [weak self] filter in
                guard let self else { return }
                self.windowFilter = filter
                self.windowName = Self.describe(filter)
                if self.source == .window { self.restartCapture() } else { self.source = .window }
            }
            picker.add(o)
            pickerObserver = o
        }
        var cfg = SCContentSharingPickerConfiguration()
        cfg.allowedPickerModes = [.singleWindow, .singleApplication]
        cfg.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? ""]
        picker.defaultConfiguration = cfg
        picker.isActive = true
        picker.present()
    }

    private static func describe(_ f: SCContentFilter) -> String {
        let r = f.contentRect
        return r.width > 0 ? "Window (\(Int(r.width))×\(Int(r.height)))" : "A window"
    }

    private func sourceChanged(from old: Source) {
        if case .phones = old, source != .phones { uxplay?.terminate(); uxplay = nil }
        if source == .phones, !selected.isEmpty, uxplay == nil { startUxPlay() }
        preview = nil
        restartCapture()
    }

    private func restartCapture() {
        capturing = false
        streamer.stop()
        updateCapture()
    }

    private func updateCapture() {
        let want = !selected.isEmpty
        if !want {
            if capturing || streamer.audio.isRunning { capturing = false; streamer.stop() }
            return
        }
        guard !capturing else { return }
        switch source {
        case .testPattern:
            do { try streamer.startTestPattern(); capturing = true }
            catch { message = error.localizedDescription }
        case .phones:
            // UxPlay sends the phone's video (and sound, when on). Without
            // phone sound, keep a silent track running for the TVs.
            if !sendAudio { streamer.audio.muted = true; streamer.audio.start() } else { streamer.audio.stop() }
        case .window:
            guard let filter = windowFilter else { chooseWindow(); return }
            capture { s in
                try await s.start(filter: filter, contentSize: filter.contentRect.size, captureAudio: self.sendAudio)
            }
        case .display(let id), .region(let id):
            guard hasScreenAccess else {
                message = "Screen Recording permission is needed to show this screen. Use Open Settings, then Relaunch."
                return
            }
            let rect: CGRect? = { if case .region = source { return region } else { return nil } }()
            capture { s in
                let all = try await ScreenStreamer.displays()
                guard let d = all.first(where: { $0.displayID == id }) ?? all.first else { return }
                try await s.start(display: d, sourceRect: rect, captureAudio: self.sendAudio)
            }
        }
    }

    private func capture(_ start: @escaping (ScreenStreamer) async throws -> Void) {
        capturing = true
        Task {
            do { try await start(streamer) }
            catch {
                capturing = false
                message = "Couldn't start sharing: \(error.localizedDescription)"
            }
        }
    }

    private func startUxPlay() {
        guard let bin = tool("uxplay") else { message = "uxplay binary not found"; return }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["-n", Self.receiverName, "-nh", "-m", "02:5a:11:7e:00:01", "-p", "7300",
                       "-s", "1920x1080", "-fps", "30", "-nohold",
                       "-vrtp", "config-interval=1 ! udpsink host=127.0.0.1 port=\(Self.rtpPort)"]
            + (sendAudio ? ["-artp", "pt=96 ! udpsink host=127.0.0.1 port=\(Self.audioPort)"] : [])
        p.environment = toolEnvironment()
        let log = stateDir.appendingPathComponent("uxplay.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        p.standardOutput = try? FileHandle(forWritingTo: log)
        p.standardError = p.standardOutput
        do { try p.run(); uxplay = p } catch { message = "Could not start UxPlay: \(error.localizedDescription)" }
    }

    // MARK: helpers

    /// Bundled tools live in Contents/Resources/bin; fall back to SPLITTER_BIN.
    private func tool(_ name: String) -> URL? {
        var dirs: [URL] = []
        if let r = Bundle.main.resourceURL { dirs.append(r.appendingPathComponent("bin")) }
        if let env = ProcessInfo.processInfo.environment["SPLITTER_BIN"] { dirs.append(URL(fileURLWithPath: env)) }
        return dirs.map { $0.appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Apps launched from Finder get a bare PATH; doubletake needs gst-launch-1.0.
    private func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        guard let gst = Self.bundledGStreamer else {
            // Development run outside the app bundle: use Homebrew's GStreamer.
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
            return env
        }
        // Use only the GStreamer inside the app, never a Homebrew copy.
        env["PATH"] = gst.appendingPathComponent("bin").path + ":/usr/bin:/bin"
        env["GST_PLUGIN_SYSTEM_PATH"] = gst.appendingPathComponent("lib/gstreamer-1.0").path
        env["GST_PLUGIN_PATH"] = ""
        env["GST_PLUGIN_SCANNER"] = gst.appendingPathComponent("libexec/gst-plugin-scanner").path
        env["GST_REGISTRY"] = stateDir.appendingPathComponent("gst-registry.bin").path
        env.removeValue(forKey: "DYLD_LIBRARY_PATH")
        return env
    }

    /// Contents/Resources/gst when the app carries its own GStreamer.
    static let bundledGStreamer: URL? = {
        guard let r = Bundle.main.resourceURL?.appendingPathComponent("gst"),
              FileManager.default.isExecutableFile(atPath: r.appendingPathComponent("bin/gst-launch-1.0").path)
        else { return nil }
        return r
    }()
}

/// Receives the choice from macOS's sharing picker.
final class PickerObserver: NSObject, SCContentSharingPickerObserver {
    private let onPick: @MainActor (SCContentFilter) -> Void
    init(onPick: @escaping @MainActor (SCContentFilter) -> Void) { self.onPick = onPick }

    func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor in self.onPick(filter) }
    }
    func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {}
    func contentSharingPickerStartDidFailWithError(_ error: Error) {}
}
