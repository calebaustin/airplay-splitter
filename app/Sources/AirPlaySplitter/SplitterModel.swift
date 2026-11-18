import Foundation
import ScreenCaptureKit
import AppKit

@MainActor
final class SplitterModel: ObservableObject {
    enum Source: Hashable {
        case display(CGDirectDisplayID)
        case phones          // iPhone/iPad mirroring to "AirPlay Splitter" (UxPlay)
        case testPattern     // moving test card; needs no permission
    }

    /// Screen Recording permission. macOS only applies a new grant after the
    /// app restarts, so this is read once at launch.
    @Published var hasScreenAccess = CGPreflightScreenCaptureAccess()

    /// doubletake runs gst-launch-1.0 from Homebrew; others installing the
    /// DMG may not have it yet.
    let gstreamerMissing = !["/opt/homebrew/bin/gst-launch-1.0", "/usr/local/bin/gst-launch-1.0"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }

    var needsScreenAccess: Bool {
        if case .display = source { return !hasScreenAccess }
        return false
    }

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
    static let receiverName = "AirPlay Splitter"

    private let stateDir: URL
    private let client: DaemonClient
    private var daemon: Process?
    private var uxplay: Process?
    private let streamer = ScreenStreamer(rtpPort: rtpPort)
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

    private func sourceChanged(from old: Source) {
        if case .phones = old, source != .phones { uxplay?.terminate(); uxplay = nil }
        if source == .phones, !selected.isEmpty { startUxPlay() }
        capturing = false
        streamer.stop()
        updateCapture()
    }

    private func updateCapture() {
        let want = !selected.isEmpty
        if source == .testPattern {
            if want && !capturing {
                do { try streamer.startTestPattern(); capturing = true }
                catch { message = error.localizedDescription }
            } else if !want && capturing {
                capturing = false
                streamer.stop()
            }
            return
        }
        guard case .display(let id) = source else { streamer.stop(); capturing = false; return }
        if want && !capturing && !hasScreenAccess {
            message = "Screen Recording permission is needed to show this screen. Use Open Settings, then Relaunch."
            return
        }
        if want && !capturing {
            capturing = true
            Task {
                do {
                    let all = try await ScreenStreamer.displays()
                    guard let d = all.first(where: { $0.displayID == id }) ?? all.first else { return }
                    try await streamer.start(display: d)
                } catch {
                    capturing = false
                    message = "Screen capture failed: \(error.localizedDescription). Check Screen Recording permission."
                }
            }
        } else if !want && capturing {
            capturing = false
            streamer.stop()
        }
    }

    private func startUxPlay() {
        guard let bin = tool("uxplay") else { message = "uxplay binary not found"; return }
        let p = Process()
        p.executableURL = bin
        p.arguments = ["-n", Self.receiverName, "-nh", "-m", "02:5a:11:7e:00:01", "-p", "7300",
                       "-s", "1920x1080", "-fps", "30", "-nohold",
                       "-vrtp", "config-interval=1 ! udpsink host=127.0.0.1 port=\(Self.rtpPort)"]
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
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        return env
    }
}
