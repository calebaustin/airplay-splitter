import SwiftUI
import UniformTypeIdentifiers

/// The Content page: things the app puts on the TVs by itself, without
/// sharing the screen. Each card has a Show button; the one live now is marked.
struct ContentPage: View {
    @ObservedObject var model: SplitterModel

    var body: some View {
        VStack(spacing: Tokens.gap) {
            ImageCard(model: model)
            HoldingCard(model: model)
            CountdownCard(model: model)
        }
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

// MARK: holding screen

private struct HoldingCard: View {
    @ObservedObject var model: SplitterModel
    @State private var title = ""
    @State private var subtitle = ""
    @State private var color = Color.blue

    var body: some View {
        Card(title: "Holding Screen", symbol: "rectangle.inset.filled", live: model.source == .holding) {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Title", text: $title).onSubmit(commit)
                TextField("Subtitle", text: $subtitle).onSubmit(commit)
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
            .textFieldStyle(.roundedBorder)
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
    @State private var custom = 20

    var body: some View {
        Card(title: "Countdown", symbol: "timer", live: model.source == .countdown) {
            if model.source == .countdown, let end = model.countdownEnd {
                HStack {
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        Text(remaining(until: end)).font(.title3.monospacedDigit().weight(.semibold))
                    }
                    Text("on the holding screen").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Stop") { model.stopCountdown() }.controlSize(.small)
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        ForEach([5, 10, 15, 30], id: \.self) { m in
                            Button("\(m) min") { model.startCountdown(minutes: m) }
                        }
                    }
                    HStack(spacing: 6) {
                        Stepper(value: $custom, in: 1...180) {
                            Text("\(custom) min").monospacedDigit()
                        }
                        Spacer()
                        Button("Start") { model.startCountdown(minutes: custom) }.buttonStyle(.borderedProminent)
                    }
                    Text("Uses the holding screen's background, logo and title.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .controlSize(.small)
            }
        }
    }

    private func remaining(until end: Date) -> String {
        let s = max(0, Int(end.timeIntervalSinceNow.rounded(.up)))
        return s == 0 ? "Starting now" : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: helpers

@MainActor
private func openPanel(images: Bool) -> URL? {
    let p = NSOpenPanel()
    p.allowedContentTypes = images ? [.image] : [.item]
    p.allowsMultipleSelection = false
    p.canChooseDirectories = false
    NSApp.activate(ignoringOtherApps: true)
    return p.runModal() == .OK ? p.url : nil
}
