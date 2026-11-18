import SwiftUI

// Design tokens. Views read these, never raw values.
enum Tokens {
    static let radius: CGFloat = 14
    static let rowRadius: CGFloat = 10
    static let gap: CGFloat = 12
    static let pad: CGFloat = 14
    static let width: CGFloat = 340
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
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.on.rectangle")
                .font(.system(size: 15, weight: .semibold))
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

    // MARK: source

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Show")
            HStack(spacing: 10) {
                Image(systemName: model.sourceSymbol)
                    .foregroundStyle(.secondary).frame(width: 20)
                Picker("Show", selection: $model.source) {
                    ForEach(model.displays) { d in
                        Text(d.name).tag(SplitterModel.Source.display(d.id))
                    }
                    Divider()
                    Text("iPhone or iPad").tag(SplitterModel.Source.phones)
                    Text("Test pattern").tag(SplitterModel.Source.testPattern)
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .glass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
            if model.source == .phones {
                Text("On the iPhone or iPad, open Control Center, tap Screen Mirroring, and choose “AirPlay Splitter”.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: receivers

    private var receiversSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionLabel("Send to")
            VStack(spacing: 0) {
                if model.tvs.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for AirPlay TVs on your network").foregroundStyle(.secondary)
                    }
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                }
                ForEach(Array(model.tvs.enumerated()), id: \.element.id) { i, tv in
                    if i > 0 { Divider().opacity(0.5).padding(.leading, 44) }
                    ReceiverRow(model: model, tv: tv)
                }
            }
            .glass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
        }
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
        guard model.selected.contains(tv.ip) else { return nil }
        return switch model.streams[tv.ip]?.state {
            case "streaming": ("Showing", Tokens.live)
            case "pin_required": ("Waiting for PIN", Tokens.busy)
            case "connecting": ("Connecting", Tokens.busy)
            default: (needsPIN ? "Waiting for PIN" : "Connecting", Tokens.busy)
        }
    }
}
