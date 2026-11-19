import SwiftUI

// Design tokens. Views read these, never raw values.
enum Tokens {
    static let radius: CGFloat = 14
    static let rowRadius: CGFloat = 10
    static let gap: CGFloat = 12
    static let pad: CGFloat = 14
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 40   // one TV row (34pt content + divider)
    static let pinHeight: CGFloat = 62   // the PIN box under a row
    static let live = Color.green
    static let busy = Color.orange
    static let warn = Color.orange
}

/// Liquid Glass on macOS 26, frosted material before that.
private struct Glass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
    }
}

private extension View {
    func glass<S: Shape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(Glass(shape: shape, interactive: interactive))
    }
    @ViewBuilder func glassGroup() -> some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: Tokens.gap) { self } } else { self }
    }
}

struct SplitterMenu: View {
    @ObservedObject var model: SplitterModel

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.gap) {
            header
            if let u = model.update { updateCard(u) }
            if model.gstreamerMissing { gstreamerNotice }
            sourceSection
            if model.needsScreenAccess { accessNotice }
            receiversSection
            if let msg = model.message { messageRow(msg) }
            footer
        }
        .padding(Tokens.pad)
        .frame(width: Tokens.width)
        .glassGroup()
        .task { await model.loadDisplays() }
        .onAppear { model.previewVisible = true }
        .onDisappear { model.previewVisible = false }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            MenuBarIcon(active: true)
                .foregroundStyle(model.liveCount > 0 ? Tokens.live : .secondary)
                .frame(width: 30, height: 30)
                .glass(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("AirPlay Splitter").font(.headline)
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    // MARK: update

    private func updateCard(_ u: Updater.Update) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Version \(u.version) is available").font(.callout.weight(.semibold))
                    Text("Open the download, drag AirPlay Splitter onto Applications and choose Replace. Then quit this copy and open the new one.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } icon: {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
            }
            HStack {
                Button("What's New") { model.updater.openReleasePage() }.buttonStyle(.borderless)
                Spacer()
                Button("Later") { model.updater.skip() }
                Button("Download") { model.updater.download() }.buttonStyle(.borderedProminent)
            }
            .controlSize(.small)
        }
        .padding(10)
        .glass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
    }

    // MARK: source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Show")
            HStack(spacing: 10) {
                previewThumb
                VStack(alignment: .leading, spacing: 6) {
                    sourceMenu
                    Toggle(isOn: $model.sendAudio) {
                        Label("Sound", systemImage: model.sendAudio ? "speaker.wave.2.fill" : "speaker.slash")
                            .font(.callout)
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!model.audioAvailable)
                    .help("Send this Mac's sound to the TVs too")
                }
            }
            .padding(8)
            .glass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
            if model.source == .phones {
                Text("On the iPhone or iPad, open Control Center, tap Screen Mirroring, and choose “AirPlay Splitter”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What's on the TVs right now, or the source's icon when nothing is live.
    private var previewThumb: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous)
                .fill(.black.opacity(0.25))
            if let img = model.preview, !model.selected.isEmpty {
                Image(decorative: img, scale: 1)
                    .resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: model.sourceSymbol).font(.title2).foregroundStyle(.secondary)
            }
        }
        .frame(width: 112, height: 63)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.rowRadius, style: .continuous))
        .accessibilityLabel("Preview of what's being sent")
    }

    private var sourceMenu: some View {
        Menu {
            Section("Screens") {
                ForEach(model.displays) { d in
                    Button { model.chooseDisplay(d.id) } label: {
                        Label(d.name, systemImage: model.source == .display(d.id) ? "checkmark" : "display")
                    }
                }
            }
            Section("Part of the screen") {
                Button { model.chooseWindow() } label: { Label("Choose a Window…", systemImage: "macwindow") }
                ForEach(model.displays) { d in
                    Button { model.chooseRegion(on: d.id) } label: {
                        Label(model.displays.count > 1 ? "Select an Area of \(d.name.components(separatedBy: " (").first ?? "Screen")…"
                                                       : "Select an Area…", systemImage: "rectangle.dashed")
                    }
                }
            }
            Section {
                Button { model.choosePhones() } label: { Label("iPhone or iPad", systemImage: "iphone") }
                Button { model.chooseTestPattern() } label: { Label("Test Pattern", systemImage: "square.grid.3x3.topleft.filled") }
            }
        } label: {
            Label(model.sourceName, systemImage: model.sourceSymbol).lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: receivers

    private var receiversSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("Send to")
                Spacer()
                Button { model.refreshTVs() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).foregroundStyle(.secondary).controlSize(.small)
                    .help("Look for TVs again")
            }
            if model.selected.isEmpty, !model.lastGroupNames.isEmpty { lastGroupCard }
            Group {
                if model.tvs.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for AirPlay TVs on your network").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                } else {
                    // Capped height so the menu always fits under the menu bar,
                    // however many TVs a building has. Switched-on TVs sort first.
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            LazyVStack(spacing: 0) {
                                ForEach(Array(orderedTVs.enumerated()), id: \.element.id) { i, tv in
                                    if i > 0 { Divider().opacity(0.5).padding(.leading, 44) }
                                    ReceiverRow(model: model, tv: tv).id(tv.id)
                                }
                            }
                        }
                        .scrollIndicators(.automatic)
                        .frame(height: listHeight)
                        .onChange(of: model.pinFor?.ip) { _, ip in
                            if let ip { withAnimation { proxy.scrollTo(ip, anchor: .center) } }
                        }
                    }
                }
            }
            .glass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
            if model.tvs.count > visibleRows {
                Text("\(model.tvs.count) TVs found. Scroll for more.")
                    .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 4)
            }
        }
    }

    /// Switched-on TVs first, then the rest alphabetically.
    private var orderedTVs: [DaemonClient.Device] {
        model.tvs.sorted { a, b in
            let sa = model.selected.contains(a.ip), sb = model.selected.contains(b.ip)
            if sa != sb { return sa }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// Rows that fit: about 45% of the screen, between 4 and 7 rows.
    private var visibleRows: Int {
        let screen = NSScreen.main?.visibleFrame.height ?? 800
        return max(4, min(7, Int(screen * 0.45 / Tokens.rowHeight)))
    }

    private var listHeight: CGFloat {
        let rows = CGFloat(min(model.tvs.count, visibleRows))
        let statusLines = CGFloat(model.selected.count) * 14
        let pin: CGFloat = model.pinFor == nil ? 0 : Tokens.pinHeight
        let natural = CGFloat(model.tvs.count) * Tokens.rowHeight + statusLines + pin
        return min(natural, rows * Tokens.rowHeight + pin)
    }

    private var lastGroupCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("Last time").font(.caption.weight(.semibold))
                Text(model.lastGroupNames.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Reconnect") { model.reconnectLastGroup() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .glass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
    }

    // MARK: notices

    private var accessNotice: some View {
        notice(symbol: "lock.display",
               text: "To show your screen, allow Screen Recording for AirPlay Splitter, then relaunch.") {
            Button("Open Settings") { model.requestScreenAccess() }
            Button("Relaunch") { model.relaunch() }.buttonStyle(.borderedProminent)
        }
    }

    private var gstreamerNotice: some View {
        notice(symbol: "shippingbox",
               text: "AirPlay Splitter needs GStreamer. In Terminal, run: brew install gstreamer") {
            Button("Copy command") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install gstreamer", forType: .string)
            }
        }
    }

    private func notice<Actions: View>(symbol: String, text: String,
                                       @ViewBuilder actions: () -> Actions) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: symbol).foregroundStyle(Tokens.warn)
            }
            .font(.callout)
            HStack { Spacer(); actions() }.controlSize(.small)
        }
        .padding(10)
        .glass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
    }

    private func messageRow(_ msg: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.circle").foregroundStyle(Tokens.warn)
            Text(msg).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { model.message = nil } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    // MARK: footer

    private var footer: some View {
        HStack {
            Button("Stop All") { model.stopAll() }
                .disabled(model.selected.isEmpty)
            Spacer()
            Toggle(isOn: $model.blanked) {
                Label(model.blanked ? "Unblank" : "Blank", systemImage: model.blanked ? "eye" : "eye.slash")
            }
            .toggleStyle(.button)
            .disabled(model.selected.isEmpty || model.source == .phones)
            .help("Show black on every TV without disconnecting")
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.regular)
        .modifier(GlassButtons())
    }

    private func sectionLabel(_ s: String) -> some View {
        Text(s).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.leading, 4)
    }
}

private struct GlassButtons: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) { content.buttonStyle(.glass) } else { content.buttonStyle(.bordered) }
    }
}

/// One TV: icon, name, live status, switch. Its PIN entry opens right beneath it.
struct ReceiverRow: View {
    @ObservedObject var model: SplitterModel
    let tv: DaemonClient.Device
    @State private var pin = ""
    @FocusState private var pinFocused: Bool

    private var isOn: Binding<Bool> {
        Binding(get: { model.selected.contains(tv.ip) }, set: { _ in model.toggle(tv) })
    }
    private var needsPIN: Bool { model.pinFor?.ip == tv.ip }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                    .foregroundStyle(model.selected.contains(tv.ip) ? Color.accentColor : .secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(tv.name).lineLimit(1).truncationMode(.tail)
                        .foregroundStyle(model.missing.contains(tv.ip) && !model.selected.contains(tv.ip) ? .secondary : .primary)
                    if let (label, color) = status {
                        HStack(spacing: 4) {
                            Circle().fill(color).frame(width: 6, height: 6)
                            Text(label).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 8)
                Toggle(tv.name, isOn: isOn)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())

            if needsPIN { pinEntry.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .animation(.snappy(duration: 0.2), value: needsPIN)
    }

    private var pinEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter the PIN shown on this TV.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("PIN", text: $pin)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 96)
                    .focused($pinFocused)
                    .onSubmit(submit)
                Button("Pair", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Cancel") { model.toggle(tv) }.buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            .controlSize(.small)
        }
        .padding(.leading, 44).padding(.trailing, 10).padding(.bottom, 10)
        .onAppear { pinFocused = true }
    }

    private func submit() {
        let p = pin.trimmingCharacters(in: .whitespaces)
        guard !p.isEmpty else { return }
        model.submitPIN(p)
        pin = ""
    }

    private var symbol: String {
        let m = tv.model.lowercased()
        if m.hasPrefix("appletv") { return "appletv" }
        if m.hasPrefix("mac") { return "laptopcomputer" }
        if m.hasPrefix("audioaccessory") { return "homepod" }
        return "tv"
    }

    private var status: (String, Color)? {
        guard model.selected.contains(tv.ip) else {
            return model.missing.contains(tv.ip) ? ("Not found right now", .secondary) : nil
        }
        if model.reconnecting.contains(tv.ip), model.streams[tv.ip]?.state != "streaming" {
            return ("Reconnecting", Tokens.busy)
        }
        return switch model.streams[tv.ip]?.state {
            case "streaming": ("Showing", Tokens.live)
            case "pin_required": ("Waiting for PIN", Tokens.busy)
            case "connecting": ("Connecting", Tokens.busy)
            default: (needsPIN ? "Waiting for PIN" : "Connecting", Tokens.busy)
        }
    }
}
