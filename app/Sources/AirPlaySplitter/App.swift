import SwiftUI
import CoreImage

/// Caleb's icon as a template image, so macOS tints it for the menu bar.
/// Dimmed while nothing is being sent.
struct MenuBarIcon: View {
    let active: Bool
    var badge = false
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        let h: CGFloat = 16
        img.size = NSSize(width: h * img.size.width / img.size.height, height: h)
        return img
    }()

    var body: some View {
        if let img = Self.image {
            Image(nsImage: img).opacity(active || badge ? 1 : 0.6)
                .overlay(alignment: .topTrailing) {
                    if badge { Circle().fill(Color.accentColor).frame(width: 5, height: 5).offset(x: 2, y: -1) }
                }
        } else {
            Image(systemName: active ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle")
        }
    }
}

@main
struct AirPlaySplitterApp: App {
    @StateObject private var model = SplitterModel()

    init() {
        // Developer check: `AirPlay Splitter --rtp-selftest` streams the test
        // card to the relay port for 8 s and exits (no daemon, no UI).
        if CommandLine.arguments.contains("--rtp-selftest") {
            let s = ScreenStreamer(rtpPort: SplitterModel.rtpPort, audioPort: SplitterModel.audioPort)
            do { try s.startTestPattern() } catch { print(error); exit(1) }
            s.blank = CommandLine.arguments.contains("--blank")
            RunLoop.main.run(until: Date().addingTimeInterval(8))
            s.stop()
            exit(0)
        }
        // Developer check: `--check-update` runs one update check and prints it.
        if CommandLine.arguments.contains("--check-update") {
            MainActor.assumeIsolated {
                let u = Updater()
                Task { @MainActor in
                    await u.check()
                    print(u.available.map { "update \($0.version) \($0.dmgURL)" } ?? "up to date")
                    exit(0)
                }
            }
            RunLoop.main.run(until: Date().addingTimeInterval(20))
            exit(1)
        }
        // Developer check: `--selftest-content video <file> <out.png>` or
        // `--selftest-content web <url> <out.png>` streams that content (with a
        // video's sound) to the relay ports for 8 s and saves the last frame.
        if let i = CommandLine.arguments.firstIndex(of: "--selftest-content"), i + 3 < CommandLine.arguments.count {
            let kind = CommandLine.arguments[i + 1], target = CommandLine.arguments[i + 2]
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 3])
            MainActor.assumeIsolated {
                NSApplication.shared.setActivationPolicy(.accessory)
                NSApplication.shared.finishLaunching()
                let s = ScreenStreamer(rtpPort: SplitterModel.rtpPort, audioPort: SplitterModel.audioPort)
                let video = VideoSource(), web = WebSource()
                var frame: () -> CVPixelBuffer? = { nil }
                if kind == "video" {
                    let pump = s.audio
                    video.onAudio = { c, n, r in pump.appendFloat(channels: c, frames: n, sampleRate: r) }
                    Task { @MainActor in try? await video.load(URL(fileURLWithPath: target)); video.play() }
                    frame = { video.frame() }
                    try? s.startGenerated(sound: true) { _ in video.frame() }
                } else {
                    web.load(URL(string: target)!)
                    frame = { web.frame() }
                    try? s.startGenerated { _ in web.frame() }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(8))
                if kind == "web" { print("web loading=\(web.loading) failed=\(web.failed ?? "none")") }
                if let pb = frame(), let cg = CIContext().createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: 1920, height: 1080)) {
                    try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?.write(to: out)
                }
                s.stop()
            }
            exit(0)
        }
        // Developer check: `--render-content dir` writes holding and countdown frames.
        if let i = CommandLine.arguments.firstIndex(of: "--render-content"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let d = HoldingDesign.load()
            let logo = d.logoPath.flatMap { NSImage(contentsOfFile: $0) }
            for (name, pb) in [("holding", ContentRenderer.holding(d, logo: logo)),
                               ("countdown", ContentRenderer.countdown(d, logo: logo, remaining: 9 * 60 + 41))] {
                guard let pb, let cg = CIContext().createCGImage(CIImage(cvPixelBuffer: pb), from: CGRect(x: 0, y: 0, width: 1920, height: 1080))
                else { continue }
                try? NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("\(name).png"))
            }
            exit(0)
        }
        // Developer check: `--render-menu out.png` draws the menu with sample data.
        if let i = CommandLine.arguments.firstIndex(of: "--render-menu"), i + 1 < CommandLine.arguments.count {
            MainActor.assumeIsolated { renderMenu(to: CommandLine.arguments[i + 1]) }
            exit(0)
        }
    }

    @MainActor private func renderMenu(to path: String) {
        let m = SplitterModel(preview: true)
        let dev = { (n: String, model: String, ip: String) in
            DaemonClient.Device(name: n, model: model, ip: ip, port: 7000, device_id: ip) }
        m.tvs = [dev("[LG] webOS TV UQ7070ZUE", "LG", "10.0.0.5"), dev("Bonus Room", "UTU7000", "10.0.0.184"),
                 dev("Family Room", "UTU7000", "10.0.0.186"), dev("Garage", "AppleTV11,1", "10.0.0.7"),
                 dev("Living Room", "AppleTV14,1", "10.0.0.8")]
            + (CommandLine.arguments.contains("--many")
               ? [205, 207, 208, 223, 227, 229, 308, 310, 326, 402].map { dev("\($0)", "AppleTV11,1", "10.0.1.\($0 % 250)") }
               : [])
        m.selected = ["10.0.0.5", "10.0.0.184", "10.0.0.186"]
        m.streams = ["10.0.0.184": .init(device: "Bonus Room", device_ip: "10.0.0.184", state: "streaming", width: nil, height: nil, encoder: nil),
                     "10.0.0.186": .init(device: "Family Room", device_ip: "10.0.0.186", state: "streaming", width: nil, height: nil, encoder: nil)]
        m.pinFor = m.tvs[0]
        m.displays = [.init(id: 1, name: "VY249 (1920×1080)")]
        m.source = .display(1)
        m.hasScreenAccess = true
        // Optional `--preview-image file.png` fills the preview thumbnail.
        if let j = CommandLine.arguments.firstIndex(of: "--preview-image"), j + 1 < CommandLine.arguments.count,
           let img = NSImage(contentsOfFile: CommandLine.arguments[j + 1]) {
            m.preview = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }
        // ImageRenderer can't draw AppKit-backed controls; host it in a window.
        _ = NSApplication.shared
        let host = NSHostingView(rootView: SplitterMenu(model: m, page: CommandLine.arguments.contains("--content") ? 1 : 0))
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        win.appearance = NSAppearance(named: CommandLine.arguments.contains("--dark") ? .darkAqua : .aqua)
        let effect = NSVisualEffectView(frame: host.frame)
        effect.material = .popover
        effect.state = .active
        effect.addSubview(host)
        win.contentView = effect
        win.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        win.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        guard let rep = effect.bitmapImageRepForCachingDisplay(in: effect.bounds) else { return }
        effect.cacheDisplay(in: effect.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }

    var body: some Scene {
        MenuBarExtra {
            SplitterMenu(model: model)
        } label: {
            MenuBarIcon(active: !model.selected.isEmpty, badge: model.update != nil)
        }
        .menuBarExtraStyle(.window)
    }
}
