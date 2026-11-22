import Foundation
import ScreenCaptureKit
import AppKit
import Combine

@MainActor
final class SplitterModel: ObservableObject {
    enum Source: Hashable {
        case display(CGDirectDisplayID)
        case extended                    // a 1920×1080 virtual second screen (VirtualScreen)
        case region(CGDirectDisplayID)   // part of a display; rect in `region`
        case window                      // chosen with the system sharing picker
        case phones                      // iPhone/iPad mirroring to "AirPlay Splitter" (UxPlay)
        case testPattern                 // moving test card; needs no permission
        case image                       // a still image (`imagePath`)
        case holding                     // the holding screen (`holding`)
        case countdown                   // a countdown to `countdownEnd`
        case video                       // a video file (`videoPath`)
        case web                         // a web page (`webURL`)
    }

    /// Video playback for `.video`, and the file, remembered between launches.
    let video = VideoSource()
    @Published private(set) var videoPath: String? = UserDefaults.standard.string(forKey: "videoPath")
    /// The hidden browser for `.web`, and its address.
    let web = WebSource()
    @Published var webURL: String = UserDefaults.standard.string(forKey: "webURL") ?? ""

    // MARK: content (drawn by the app, so no Screen Recording needed)

    /// The image for `.image`, remembered between launches.
    @Published private(set) var imagePath: String? = UserDefaults.standard.string(forKey: "imagePath")
    /// Holding-screen and countdown design, remembered between launches.
    @Published var holding = HoldingDesign.load() {
        didSet {
            holding.save()
            if source == .holding || source == .countdown { restartCapture() }
        }
    }
    /// When the countdown reaches zero.
    @Published private(set) var countdownEnd: Date?
    var isContent: Bool { [.image, .holding, .countdown, .video, .web].contains(source) }

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

    /// Screen Recording permission. Read at launch and checked again whenever
    /// the menu opens or sharing starts, so a grant made while the app is
    /// running is noticed without guessing.
    @Published var hasScreenAccess = CGPreflightScreenCaptureAccess()

    func refreshScreenAccess() {
        guard !isPreview else { return }
        let now = CGPreflightScreenCaptureAccess()
        if now != hasScreenAccess { hasScreenAccess = now }
    }

    /// doubletake runs gst-launch-1.0 from Homebrew; others installing the
    /// DMG may not have it yet.
    let gstreamerMissing = SplitterModel.bundledGStreamer == nil &&
        !["/opt/homebrew/bin/gst-launch-1.0", "/usr/local/bin/gst-launch-1.0"]
        .contains { FileManager.default.isExecutableFile(atPath: $0) }

    var needsScreenAccess: Bool {
        switch source {
        case .display, .region, .extended: return !hasScreenAccess
        default: return false   // the window picker grants its own access
        }
    }

    var sourceName: String {
        switch source {
        case .display(let id): displays.first { $0.id == id }?.name.components(separatedBy: " (").first ?? "Screen"
        case .region(let id):
            "Part of \(displays.first { $0.id == id }?.name.components(separatedBy: " (").first ?? "screen")"
        case .window: windowName ?? "A window"
        case .extended: "Extended Screen (1920×1080)"
        case .phones: "iPhone or iPad"
        case .testPattern: "Test pattern"
        case .image: imagePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Image"
        case .holding: "Holding screen"
        case .countdown: "Countdown"
        case .video: videoPath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "Video"
        case .web: URL(string: webURL)?.host ?? "Web page"
        }
    }

    /// Sound can come from the Mac (screen, region, window) or the phone.
    var audioAvailable: Bool { source == .video || (source != .testPattern && !isContent) }

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
        case .extended: "rectangle.on.rectangle"
        case .region: "rectangle.dashed"
        case .window: "macwindow"
        case .phones: "iphone"
        case .testPattern: "square.grid.3x3.topleft.filled"
        case .image: "photo"
        case .holding: "rectangle.inset.filled"
        case .countdown: "timer"
        case .video: "film"
        case .web: "globe"
        }
    }

    struct DisplayChoice: Identifiable, Hashable {
        let id: CGDirectDisplayID
        let name: String
    }

    /// TVs found on the network now, plus remembered TVs that were used before.
    @Published var tvs: [DaemonClient.Device] = []
    /// TVs remembered from earlier that aren't on the network right now.
    @Published private(set) var missing: Set<String> = []          // by IP
    @Published var streams: [String: DaemonClient.Stream] = [:]   // by IP
    @Published var selected: Set<String> = [] {                    // IPs the user ticked
        didSet { selectionChanged() }
    }
    /// Switched-on TVs that dropped and are being reconnected automatically.
    @Published private(set) var reconnecting: Set<String> = []
    /// Black screens and silence on every TV, without disconnecting.
    @Published var blanked = false { didSet { streamer.blank = blanked } }

    /// Saved groups of TVs, and timed actions (see Places.swift).
    @Published var places: [Place] = PlacesStore.loadPlaces() { didSet { if !isPreview { PlacesStore.savePlaces(places) } } }
    @Published var schedule: [ScheduleItem] = PlacesStore.loadSchedule() { didSet { if !isPreview { PlacesStore.saveSchedule(schedule) } } }
    /// Minute each schedule item last ran, so it runs once per minute.
    var firedSchedule: [UUID: Int] = [:]

    /// Remembered TVs, by a stable key (device ID, or name).
    private var known: [String: KnownTV] = KnownTV.load()
    private var discovered: [DaemonClient.Device] = []
    private var retries: [String: (attempts: Int, next: Date)] = [:]
    private var awake: NSObjectProtocol?
    private let outline = RegionOutline()
    /// Sample-data mode for screenshots: never touches saved settings.
    private let isPreview: Bool
    @Published var displays: [DisplayChoice] = []
    @Published var source: Source = .display(CGMainDisplayID()) { didSet { sourceChanged(from: oldValue) } }
    @Published var pinFor: DaemonClient.Device?
    @Published var message: String?

    /// A newer release on GitHub, if any (checked quietly once a day).
    @Published var update: Updater.Update?
    let updater = Updater()

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
        isPreview = preview
        stateDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AirPlaySplitter", isDirectory: true)
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        client = DaemonClient(socketPath: stateDir.appendingPathComponent("dt.sock").path)
        if preview { return }
        streamer.onPreview = { [weak self] img in
            DispatchQueue.main.async { self?.preview = img }
        }
        // A playing video's soundtrack goes to the TVs when Sound is on
        // (the pump drops it while muted).
        let pump = streamer.audio
        video.onAudio = { channels, frames, rate in
            pump.appendFloat(channels: channels, frames: frames, sampleRate: rate)
        }
        updater.$available.assign(to: &$update)
        updater.start()
        startDaemon()
        discovery.onChange = { [weak self] list in
            // NetService delivers on the main run loop.
            MainActor.assumeIsolated {
                let me = Host.current().localizedName ?? ""
                self?.discovered = list.filter { $0.name != Self.receiverName && $0.name != me }
                self?.mergeTVs()
            }
        }
        discovery.start()
        mergeTVs()
        restoreSource()
        poll = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.runSchedule() }
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
            retries[tv.ip] = nil
            reconnecting.remove(tv.ip)
            if pinFor?.ip == tv.ip { pinFor = nil }
            _ = try? client.send(["cmd": "disconnect", "target": tv.ip])
        } else {
            selected.insert(tv.ip)
            // Give the first connection a head start before smart reconnect
            // treats a missing stream as a drop.
            retries[tv.ip] = (attempts: 0, next: Date().addingTimeInterval(5))
            remember(tv, used: true)
            ensureSource()
            connect(tv, pin: nil)
        }
        updateCapture()
    }

    // MARK: memory

    /// Names of the TVs used together last time, if any.
    var lastGroupNames: [String] {
        (UserDefaults.standard.stringArray(forKey: "lastGroup") ?? []).compactMap { known[$0]?.name }
    }

    /// Switches the last group back on (the "Reconnect" button).
    func reconnectLastGroup() {
        for key in UserDefaults.standard.stringArray(forKey: "lastGroup") ?? [] {
            guard let k = known[key] else { continue }
            let tv = tvs.first { KnownTV.key(for: $0) == key } ?? k.device
            if !selected.contains(tv.ip) { toggle(tv) }
        }
    }

    /// True for a moment after Refresh, to show a spinner.
    @Published private(set) var refreshing = false

    func refreshTVs() {
        discovery.restart()
        refreshing = true
        Task { try? await Task.sleep(for: .seconds(3)); refreshing = false }
    }

    private func remember(_ tv: DaemonClient.Device, used: Bool) {
        let key = KnownTV.key(for: tv)
        var k = known[key] ?? KnownTV(name: tv.name, model: tv.model, ip: tv.ip, port: tv.port, deviceID: tv.device_id)
        k.name = tv.name; k.ip = tv.ip; k.port = tv.port
        if used { k.lastUsed = Date() }
        known[key] = k
        KnownTV.save(known)
    }

    /// Found TVs, plus remembered ones that were used before but aren't
    /// visible right now (so a dropped Apple TV can still be switched on).
    private func mergeTVs() {
        for tv in discovered where known[KnownTV.key(for: tv)] != nil { remember(tv, used: false) }
        let foundKeys = Set(discovered.map(KnownTV.key(for:)))
        let absent = known.filter { !foundKeys.contains($0.key) && $0.value.lastUsed != nil }.map(\.value.device)
        missing = Set(absent.map(\.ip))
        tvs = (discovered + absent)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func selectionChanged() {
        guard !isPreview else { return }
        if !selected.isEmpty {
            let keys = tvs.filter { selected.contains($0.ip) }.map(KnownTV.key(for:))
            UserDefaults.standard.set(keys, forKey: "lastGroup")
        }
        keepAwake(!selected.isEmpty)
        if selected.isEmpty { blanked = false }
        updateOutline()
    }

    private func restoreSource() {
        switch UserDefaults.standard.string(forKey: "source") {
        case "test": source = .testPattern
        case "phones": source = .phones
        case "extended": chooseExtendedScreen()
        case "holding": source = .holding
        case "image" where imagePath != nil: source = .image
        case let s? where s.hasPrefix("display:"):
            if let id = UInt32(s.dropFirst(8)), displays.contains(where: { $0.id == id }) { source = .display(id) }
        default: break
        }
    }

    private func saveSource() {
        guard !isPreview else { return }
        let value: String? = switch source {
        case .display(let id): "display:\(id)"
        case .extended: "extended"
        case .testPattern: "test"
        case .phones: "phones"
        case .holding: "holding"
        case .image: imagePath == nil ? nil : "image"
        case .region, .window, .countdown, .video, .web: nil   // chosen or started fresh each time
        }
        if let value { UserDefaults.standard.set(value, forKey: "source") }
    }

    /// Stops the Mac sleeping (display included) while anything is being sent.
    private func keepAwake(_ on: Bool) {
        if on, awake == nil {
            awake = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled, .userInitiated],
                reason: "Sending to AirPlay TVs")
        } else if !on, let a = awake {
            ProcessInfo.processInfo.endActivity(a)
            awake = nil
        }
    }

    private func updateOutline() {
        guard case .region(let id) = source, let rect = region,
              let screen = NSScreen.screens.first(where: {
                  ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
              }) else { outline.hide(); return }
        outline.show(rect, on: screen, live: !selected.isEmpty)
    }

    func submitPIN(_ pin: String) {
        guard let tv = pinFor else { return }
        pinFor = nil
        connect(tv, pin: pin.trimmingCharacters(in: .whitespaces))
    }

    func stopAll() {
        _ = try? client.send(["cmd": "disconnect"])
        selected.removeAll()
        retries.removeAll()
        reconnecting.removeAll()
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
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
                  n.uint32Value != extendedScreen.displayID else { return nil }
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

    /// - quiet: automatic retries don't show errors (the row says Reconnecting).
    private func connect(_ tv: DaemonClient.Device, pin: String?, quiet: Bool = false) {
        var req: [String: Any] = ["cmd": "connect", "target": tv.ip, "port": tv.port]
        if !tv.device_id.isEmpty { req["device_id"] = tv.device_id }
        if let pin { req["pin"] = pin }
        DispatchQueue.global().async { [client] in
            let r = try? client.send(req)
            Task { @MainActor in
                if r?.needs_pin == true || r?.needs_credential == true || r?.state == "pin_required" {
                    self.pinFor = tv
                } else if let e = r?.error, !e.isEmpty, !quiet {
                    self.message = "\(tv.name): \(e)"
                }
            }
        }
    }

    private func refresh() {
        DispatchQueue.global().async { [client] in
            let status = try? client.send(["cmd": "status"])
            Task { @MainActor in
                guard status != nil else { return }   // daemon busy or restarting
                var byIP: [String: DaemonClient.Stream] = [:]
                for s in status?.streams ?? [] { byIP[s.device_ip] = s }
                self.streams = byIP
                if let pending = byIP.values.first(where: { $0.state == "pin_required" }),
                   self.pinFor == nil, let tv = self.tvs.first(where: { $0.ip == pending.device_ip }) {
                    self.pinFor = tv
                }
                self.reconnectDropped()
            }
        }
    }

    /// Smart reconnect: a switched-on TV with no stream (it dropped, rebooted
    /// or lost Wi-Fi) is retried on its own, waiting 3, 6, 12 … up to 30 s.
    private func reconnectDropped() {
        let now = Date()
        for ip in selected {
            if let s = streams[ip] {
                if s.state == "streaming" { retries[ip] = nil; reconnecting.remove(ip) }
                continue
            }
            guard pinFor?.ip != ip, let tv = tvs.first(where: { $0.ip == ip }) else { continue }
            var r = retries[ip] ?? (attempts: 0, next: now)
            guard now >= r.next else { continue }
            r.attempts += 1
            r.next = now.addingTimeInterval(min(30, 3 * pow(2, Double(r.attempts - 1))))
            retries[ip] = r
            reconnecting.insert(ip)
            connect(tv, pin: nil, quiet: true)
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

    /// The virtual 1920×1080 second screen, while it's the source.
    let extendedScreen = VirtualScreen()

    /// Adds a 1920×1080 screen to the Mac (like plugging in a TV) and sends
    /// that to the TVs: drag slides, ProPresenter or a browser onto it while
    /// your own screen stays private. Exactly TV-shaped, so no black bars.
    func chooseExtendedScreen() {
        if isPreview { source = .extended; return }
        Task {
            guard await extendedScreen.start() else {
                message = "macOS didn't bring the extended screen online. Try again, or pick a Screen from the list."
                return
            }
            await loadDisplays()
            if source == .extended { restartCapture() } else { source = .extended }
        }
    }
    func chooseTestPattern() { source = .testPattern }

    /// Shows an image on the TVs (from the Content page, a drop or Choose…).
    func showImage(at url: URL) {
        guard NSImage(contentsOf: url) != nil else { message = "That file isn't an image AirPlay Splitter can open."; return }
        imagePath = url.path
        UserDefaults.standard.set(url.path, forKey: "imagePath")
        if source == .image { restartCapture() } else { source = .image }
    }

    func showImage() { if imagePath != nil { if source == .image { restartCapture() } else { source = .image } } }

    func showHolding() { source = .holding }

    func startCountdown(minutes: Int) {
        countdownEnd = Date().addingTimeInterval(TimeInterval(minutes * 60))
        if source == .countdown { restartCapture() } else { source = .countdown }
    }

    /// Counts down to a time of day: today, or tomorrow if it has passed.
    func startCountdown(until time: Date) {
        let cal = Calendar.current
        let hm = cal.dateComponents([.hour, .minute], from: time)
        var end = cal.date(bySettingHour: hm.hour ?? 0, minute: hm.minute ?? 0, second: 0, of: Date()) ?? time
        if end <= Date() { end = cal.date(byAdding: .day, value: 1, to: end) ?? end }
        countdownEnd = end
        if source == .countdown { restartCapture() } else { source = .countdown }
    }

    // MARK: video and web

    /// Loads a video and shows it on the TVs, playing.
    func showVideo(at url: URL) {
        Task {
            do {
                try await video.load(url)
                videoPath = url.path
                UserDefaults.standard.set(url.path, forKey: "videoPath")
                if source == .video { restartCapture() } else { source = .video }
                video.play()
            } catch {
                message = "That video couldn't be opened: \(error.localizedDescription)"
            }
        }
    }

    func showVideo() {
        guard let p = videoPath else { return }
        if source == .video, video.player.currentItem != nil { video.play() } else { showVideo(at: URL(fileURLWithPath: p)) }
    }

    /// Opens a web page on the TVs. Adds https:// if no scheme was typed.
    func showWeb() {
        var text = webURL.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        // A local page (offline signage): a path like ~/Signage/index.html.
        if text.hasPrefix("/") || text.hasPrefix("~") {
            text = URL(fileURLWithPath: (text as NSString).expandingTildeInPath).absoluteString
        } else if !text.contains("://") {
            text = "https://" + text
        }
        guard let url = URL(string: text), ["https", "http", "file"].contains(url.scheme ?? "") else {
            message = "That doesn't look like a web address."; return
        }
        webURL = text
        UserDefaults.standard.set(text, forKey: "webURL")
        web.load(url)
        if source == .web { restartCapture() } else { source = .web }
    }

    func stopCountdown() {
        countdownEnd = nil
        if source == .countdown { source = .holding }
    }

    /// Frame source for the content modes. Still content is drawn once;
    /// the countdown redraws only when the shown second changes.
    private func contentFrames() -> ((Double) -> CVPixelBuffer?)? {
        let design = holding
        let logo = design.logoPath.flatMap { NSImage(contentsOfFile: $0) }
        switch source {
        case .image:
            guard let path = imagePath, let img = NSImage(contentsOfFile: path),
                  let pb = ContentRenderer.image(img) else { message = "Choose an image first."; return nil }
            return { _ in pb }
        case .holding:
            guard let pb = ContentRenderer.holding(design, logo: logo) else { return nil }
            return { _ in pb }
        case .web:
            let w = web
            return { _ in w.frame() }
        case .countdown:
            let end = countdownEnd ?? Date()
            var lastSecond = -1
            var cached: CVPixelBuffer?
            return { _ in
                let remaining = end.timeIntervalSinceNow
                let sec = max(0, Int(remaining.rounded(.up)))
                if sec != lastSecond || cached == nil {
                    lastSecond = sec
                    cached = ContentRenderer.countdown(design, logo: logo, remaining: remaining)
                }
                return cached
            }
        default: return nil
        }
    }
    func choosePhones() { source = .phones }

    /// Drag out part of a screen. Keeps the current source if cancelled.
    func chooseRegion(on id: CGDirectDisplayID) {
        MenuPanelController.hideMenu()
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }) else { return }
        regionSelector.select(on: screen) { [weak self] rect in
            guard let self, let rect else { return }
            self.region = rect
            if self.source == .region(id) { self.updateOutline(); self.restartCapture() } else { self.source = .region(id) }
        }
    }

    /// Opens macOS's own window picker (the one FaceTime and Zoom use).
    func chooseWindow() {
        MenuPanelController.hideMenu()
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
        guard !isPreview else { return }
        if case .phones = old, source != .phones { uxplay?.terminate(); uxplay = nil }
        if source == .phones, !selected.isEmpty, uxplay == nil { startUxPlay() }
        if source == .phones { blanked = false }   // phone video bypasses the app
        if old == .video, source != .video { video.pause() }
        if old == .web, source != .web { web.stop() }
        if old == .extended, source != .extended { extendedScreen.remove() }
        preview = nil
        saveSource()
        updateOutline()
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
        case .image, .holding, .countdown, .web:
            guard let frames = contentFrames() else { return }
            do { try streamer.startGenerated(frames); capturing = true }
            catch { message = error.localizedDescription }
        case .video:
            let v = video
            do { try streamer.startGenerated(sound: sendAudio) { _ in v.frame() }; capturing = true }
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
        case .extended:
            refreshScreenAccess()
            guard hasScreenAccess else {
                message = "Screen Recording permission is needed to show the extended screen. Use Open Settings, then Relaunch."
                return
            }
            let screen = extendedScreen
            capture { s in
                guard await screen.start(), let id = screen.displayID else {
                    throw NSError(domain: "AirPlaySplitter", code: 1, userInfo: [NSLocalizedDescriptionKey: "macOS didn't bring the extended screen online."])
                }
                // A new screen takes a moment to show up for capture.
                var found: SCDisplay?
                for _ in 0..<20 {
                    found = try await ScreenStreamer.displays().first { $0.displayID == id }
                    if found != nil { break }
                    try await Task.sleep(nanoseconds: 150_000_000)
                }
                guard let d = found else { throw NSError(domain: "AirPlaySplitter", code: 1, userInfo: [NSLocalizedDescriptionKey: "The extended screen didn't appear."]) }
                try await s.start(display: d, sourceRect: nil, captureAudio: self.sendAudio)
            }
        case .display(let id), .region(let id):
            refreshScreenAccess()
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

    /// Bundled helpers live in Contents/Helpers/<role>/AirPlay Splitter, named
    /// after the app so macOS permission prompts say "AirPlay Splitter".
    /// Development runs fall back to SPLITTER_BIN/<doubletake|uxplay>.
    private func tool(_ name: String) -> URL? {
        let role = name == "uxplay" ? "receiver" : "engine"
        var candidates: [URL] = []
        candidates.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(role)/AirPlay Splitter"))
        if let env = ProcessInfo.processInfo.environment["SPLITTER_BIN"] {
            candidates.append(URL(fileURLWithPath: env).appendingPathComponent(name))
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
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

/// A TV the app has seen, kept between launches (connection memory).
struct KnownTV: Codable {
    var name: String
    var model: String
    var ip: String
    var port: Int
    var deviceID: String
    var lastUsed: Date?

    var device: DaemonClient.Device {
        DaemonClient.Device(name: name, model: model, ip: ip, port: port, device_id: deviceID)
    }

    /// Device IDs survive address changes; fall back to the name.
    static func key(for d: DaemonClient.Device) -> String { d.device_id.isEmpty ? "name:" + d.name : d.device_id }

    static func load() -> [String: KnownTV] {
        guard let data = UserDefaults.standard.data(forKey: "knownTVs"),
              let v = try? JSONDecoder().decode([String: KnownTV].self, from: data) else { return [:] }
        return v
    }

    static func save(_ v: [String: KnownTV]) {
        if let data = try? JSONEncoder().encode(v) { UserDefaults.standard.set(data, forKey: "knownTVs") }
    }
}
