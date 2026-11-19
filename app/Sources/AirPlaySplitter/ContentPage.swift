import SwiftUI
import UniformTypeIdentifiers

/// The Content page: things the app puts on the TVs by itself, without
/// sharing the screen. Each card has a Show button; the one live now is marked.
struct ContentPage: View {
    @ObservedObject var model: SplitterModel

    var body: some View {
        // Capped like the TV list, so the menu always fits under the menu bar.
        ScrollView(.vertical) {
            cards
        }
        .scrollIndicators(.automatic)
        // Fills the menu's fixed page area and scrolls inside it.
        .frame(maxHeight: .infinity, alignment: .top)
        // Glass draws in its own layer; keep it inside the scroll area.
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
    }

    @ViewBuilder private var cards: some View {
        let stack = VStack(spacing: Tokens.gap) {
            ImageCard(model: model)
            VideoCard(model: model, video: model.video)
            WebCard(model: model, web: model.web)
            HoldingCard(model: model)
            CountdownCard(model: model)
        }
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: Tokens.gap) { stack } } else { stack }
    }
}

/// Shared card chrome: title row with an optional "Showing" mark.
private struct Card<Content: View>: View {
    let title: String
    let symbol: String
    let live: Bool
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold))
                Spacer()
                if live {
                    Label("Showing", systemImage: "dot.radiowaves.left.and.right")
                        .font(.caption2.weight(.semibold)).foregroundStyle(Tokens.live)
                }
            }
            content
        }
        .padding(10)
        .modifier(CardGlass(live: live))
    }
}

private struct CardGlass: ViewModifier {
    let live: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous)
        Group {
            if #available(macOS 26.0, *) { content.glassEffect(.regular, in: shape) }
            else { content.background(.regularMaterial, in: shape) }
        }
        .overlay(shape.strokeBorder(Tokens.live.opacity(live ? 0.7 : 0), lineWidth: 1.5))
    }
}

// MARK: image

private struct ImageCard: View {
    @ObservedObject var model: SplitterModel
    @State private var targeted = false

    var body: some View {
        Card(title: "Image", symbol: "photo", live: model.source == .image) {
            HStack(spacing: 10) {
                thumb
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.imagePath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Drop an image here")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    HStack {
                        Button("Choose…") { if let url = openPanel(images: true) { model.showImage(at: url) } }
                        Button("Show") { model.showImage() }
                            .buttonStyle(.borderedProminent)
                            .disabled(model.imagePath == nil)
                    }
                    .controlSize(.small)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.showImage(at: url) } }
            }
            return true
        }
    }

    private var thumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
            if let path = model.imagePath, let img = NSImage(contentsOfFile: path) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(3)
            } else {
                Image(systemName: "arrow.down.doc").foregroundStyle(.secondary)
            }
        }
        .frame(width: 80, height: 45)
    }
}

// MARK: video

private struct VideoCard: View {
    @ObservedObject var model: SplitterModel
    @ObservedObject var video: VideoSource
    @State private var targeted = false

    var body: some View {
        Card(title: "Video", symbol: "film", live: model.source == .video) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                        .foregroundStyle(targeted ? Color.accentColor : .secondary.opacity(0.5))
                    Image(systemName: model.videoPath == nil ? "arrow.down.doc" : "film").foregroundStyle(.secondary)
                }
                .frame(width: 80, height: 45)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.videoPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Drop a video here")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: 6) {
                        Button("Choose…") { if let url = openPanel(types: [.movie, .video, .mpeg4Movie, .quickTimeMovie]) { model.showVideo(at: url) } }
                        if model.source == .video {
                            Button { video.isPlaying ? video.pause() : video.play() } label: {
                                Image(systemName: video.isPlaying ? "pause.fill" : "play.fill")
                            }.help(video.isPlaying ? "Pause" : "Play")
                            Button { video.restart() } label: { Image(systemName: "backward.end.fill") }.help("Start over")
                            Toggle(isOn: $video.loop) { Image(systemName: "repeat") }
                                .toggleStyle(.button).help("Loop")
                        } else {
                            Button("Show") { model.showVideo() }
                                .buttonStyle(.borderedProminent).disabled(model.videoPath == nil)
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            _ = providers.first?.loadObject(ofClass: URL.self) { url, _ in
                if let url { Task { @MainActor in model.showVideo(at: url) } }
            }
            return true
        }
    }
}

// MARK: web page

private struct WebCard: View {
    @ObservedObject var model: SplitterModel
    @ObservedObject var web: WebSource

    var body: some View {
        Card(title: "Web Page", symbol: "globe", live: model.source == .web) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    TextField("example.org/announcements", text: $model.webURL)
                        .onSubmit { model.showWeb() }
                        .modifier(Field())
                    if model.source == .web {
                        Button { web.reload() } label: { Image(systemName: "arrow.clockwise") }.help("Reload")
                    }
                    Button("Show") { model.showWeb() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.webURL.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .controlSize(.small)
                if model.source == .web {
                    if web.loading {
                        Text("Loading…").font(.caption2).foregroundStyle(.secondary)
                    } else if let f = web.failed {
                        Text("Couldn't load the page: \(f)").font(.caption2).foregroundStyle(Tokens.warn).lineLimit(2)
                    }
                }
            }
            .font(.callout)
        }
    }
}

// MARK: holding screen

private struct HoldingCard: View {
    @ObservedObject var model: SplitterModel
    @State private var title = ""
    @State private var subtitle = ""
    @State private var color = Color.blue

    var body: some View {
        Card(title: "Holding Screen", symbol: "rectangle.inset.filled", live: model.source == .holding) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $title).onSubmit(commit).modifier(Field())
                TextField("Subtitle", text: $subtitle).onSubmit(commit).modifier(Field())
                HStack(spacing: 8) {
                    ColorPicker("Background", selection: $color, supportsOpacity: false)
                        .labelsHidden()
                        .onChange(of: color) { _, c in
                            model.holding.background = NSColor(c).hexString
                        }
                    Button(model.holding.logoPath == nil ? "Add Logo…" : "Logo ✓") {
                        if let url = openPanel(images: true) { model.holding.logoPath = url.path }
                    }
                    if model.holding.logoPath != nil {
                        Button { model.holding.logoPath = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless).foregroundStyle(.secondary).help("Remove the logo")
                    }
                    Spacer()
                    Button("Show") { commit(); model.showHolding() }.buttonStyle(.borderedProminent)
                }
                .controlSize(.small)
            }
            .font(.callout)
        }
        .onAppear {
            title = model.holding.title
            subtitle = model.holding.subtitle
            color = Color(nsColor: NSColor(hex: model.holding.background) ?? .darkGray)
        }
    }

    /// Text is applied on Return or Show, so the TVs don't redraw on every key.
    private func commit() {
        if model.holding.title != title || model.holding.subtitle != subtitle {
            model.holding.title = title
            model.holding.subtitle = subtitle
        }
    }
}

// MARK: countdown

private struct CountdownCard: View {
    @ObservedObject var model: SplitterModel
    /// The end time for "Until": defaults to the next quarter hour.
    @State private var until = CountdownCard.nextQuarterHour()

    var body: some View {
        Card(title: "Countdown", symbol: "timer", live: model.source == .countdown) {
            if model.source == .countdown, let end = model.countdownEnd {
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(remaining(until: end)).font(.title3.monospacedDigit().weight(.semibold))
                    }
                    Text("until \(end.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { model.stopCountdown() }.controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        ForEach([5, 10, 15], id: \.self) { m in
                            Button("\(m) min") { model.startCountdown(minutes: m) }
                        }
                    }
                    HStack(spacing: 6) {
                        Text("Until").foregroundStyle(.secondary)
                        DatePicker("Until", selection: $until, displayedComponents: .hourAndMinute)
                            .labelsHidden()
                            .datePickerStyle(.stepperField)
                        Spacer()
                        Button("Start") { model.startCountdown(until: until) }.buttonStyle(.borderedProminent)
                    }
                    Text("Uses the holding screen's background, logo and title.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .controlSize(.small)
            }
        }
        .onAppear { if until < Date() { until = Self.nextQuarterHour() } }
    }

    private func remaining(until end: Date) -> String {
        let s = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        if s == 0 { return "Starting now" }
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    static func nextQuarterHour() -> Date {
        // The next :00, :15, :30 or :45 at least a minute away.
        let cal = Calendar.current
        var c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: Date().addingTimeInterval(60))
        let m = c.minute ?? 0
        c.minute = m + (15 - m % 15) % 15
        c.second = 0
        return cal.date(from: c) ?? Date()
    }
}

// MARK: helpers

/// A plain text field on a soft tint. The system's bordered style draws its
/// gray bezel first and restyles it a moment later, which flashed in the menu.
struct Field: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

@MainActor
private func openPanel(images: Bool) -> URL? { openPanel(types: images ? [.image] : [.item]) }

@MainActor
private func openPanel(types: [UTType]) -> URL? {
    let p = NSOpenPanel()
    p.allowedContentTypes = types
    p.allowsMultipleSelection = false
    p.canChooseDirectories = false
    NSApp.activate(ignoringOtherApps: true)
    return p.runModal() == .OK ? p.url : nil
}
