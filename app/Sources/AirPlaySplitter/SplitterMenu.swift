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
    /// Tallest a scrolling page may be (about 45% of the screen).
    @MainActor static var pageCap: CGFloat { max(300, (NSScreen.main?.visibleFrame.height ?? 800) * 0.45) }
    /// Tallest the whole menu may be: the screen below the menu bar, minus a margin.
    @MainActor static var menuCap: CGFloat { (NSScreen.main?.visibleFrame.height ?? 800) - 16 }
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
    /// 0 = TVs, 1 = Content. What's live stays pinned above the pages.
    @State private var page: Int
    /// How far the row is being dragged right now (0 when resting).
    @State private var drag: CGFloat = 0
    /// True while the row is being swiped or is settling; the other pages
    /// are only drawn then, so nothing of them can show at rest.
    @State private var sliding = false
    /// Edge bump already felt during this swipe (one tap per edge).
    @State private var edgeFelt = false
    @Namespace private var pill
    private let pages = ["TVs", "Content", "Places"]

    init(model: SplitterModel, page: Int = 0) {
        self.model = model
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.gap) {
            header
            if let u = model.update { updateCard(u) }
            if model.gstreamerMissing { gstreamerNotice }
            sourceSection
            if model.needsScreenAccess { accessNotice }
            // TVs / Content: swipe sideways with two fingers anywhere here;
            // the arrows and page names are there too, but optional.
            VStack(alignment: .leading, spacing: Tokens.gap) {
                pageBar
                // One fixed height for every page, so switching pages never
                // resizes the menu (resizing is what pulled it off the bar).
                // The pages sit side by side like a row of panels; swiping
                // slides the row under your fingers, and letting go settles
                // on the nearest page. Nothing fades or resizes.
                HStack(alignment: .top, spacing: Tokens.gap) {
                    pageView(0); pageView(1); pageView(2)
                }
                .offset(x: -CGFloat(page) * Self.pageStride + drag)
                .frame(width: Self.pageWidth, height: Tokens.pageCap, alignment: .topLeading)
                // Glass and dividers can draw outside a plain clip; masking
                // keeps the neighbouring pages fully out of sight.
                .mask(Rectangle())
            }
            .background(HorizontalSwipe(
                onDrag: { dx in sliding = true; drag = resisted(dx) },
                onEnd: { settle(distance: $0, velocity: $1) },
                onStep: { turn(to: page + $0) }))
            if let msg = model.message { messageRow(msg) }
            footer
        }
        .padding(Tokens.pad)
        .frame(width: Tokens.width)
        .frame(maxHeight: Tokens.menuCap)   // never taller than the screen
        .glassGroup()
        // Always hang from the menu bar, sized to fit: refit whenever something
        // that changes the menu's height changes.
        .background(MenuAnchor())
        .task { await model.loadDisplays() }
        .onAppear { model.previewVisible = true; model.refreshScreenAccess() }
        .onDisappear { model.previewVisible = false }
    }

    // MARK: header

    private var header: some View {
        HStack(spacing: 10) {
            MenuBarIcon(active: true)
                .foregroundStyle(model.liveCount > 0 ? Tokens.live : .secondary)
                .animation(Motion.fade, value: model.liveCount > 0)
                .frame(width: 30, height: 30)
                .glass(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text("AirPlay Splitter").font(.headline)
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                    .animation(Motion.snappy, value: model.summary)
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
                Button("What's New") { model.updater.openReleasePage() }.buttonStyle(.lift)
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
                    .toggleStyle(.tactile)
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
        .animation(Motion.fade, value: model.preview == nil || model.selected.isEmpty)
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

    // MARK: pages

    static let pageWidth = Tokens.width - Tokens.pad * 2
    static let pageStride = pageWidth + Tokens.gap

    @ViewBuilder private func pageView(_ i: Int) -> some View {
        // Glass is drawn by the menu-wide glass container, which ignores a
        // page's clip and opacity, so resting neighbours aren't built at all.
        Group {
            if i == page || sliding {
                switch i {
                case 0: receiversSection
                case 1: ContentPage(model: model)
                default: PlacesPage(model: model)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: Self.pageWidth, height: Tokens.pageCap, alignment: .top)
        .clipped()
        .allowsHitTesting(i == page)
    }

    /// Past the first or last page the row stretches a little and springs
    /// back, the way macOS edges feel.
    private func resisted(_ dx: CGFloat) -> CGFloat {
        let atStart = page == 0 && dx > 0
        let atEnd = page == pages.count - 1 && dx < 0
        guard atStart || atEnd else { edgeFelt = false; return dx }
        // Rubber band: easy at first, firmer the further you pull.
        let limit: CGFloat = 70
        let x = abs(dx)
        let pulled = limit * (1 - 1 / (x / limit * 0.6 + 1))
        if pulled > 18, !edgeFelt { edgeFelt = true; Haptics.align() }
        return dx < 0 ? -pulled : pulled
    }

    /// Which page label to highlight while the row moves: whichever page is
    /// mostly in view, so the pill hops over as you pass halfway.
    private var shownPage: Int {
        let p = (CGFloat(page) - drag / Self.pageStride).rounded()
        return min(max(Int(p), 0), pages.count - 1)
    }

    /// Picks the page to land on from how far and how fast the fingers moved.
    private func settle(distance: CGFloat, velocity: CGFloat) {
        // Where the row would coast to at this speed decides the page, so a
        // quick flick turns it and a slow drag past halfway does too.
        let projected = distance + velocity * 0.12
        var target = page
        if projected < -Self.pageWidth * 0.4 { target += 1 }
        else if projected > Self.pageWidth * 0.4 { target -= 1 }
        target = min(max(target, 0), pages.count - 1)
        // Hand the finger's speed to the spring so the row doesn't stall or
        // jump when you let go; it just keeps moving and settles.
        let remaining = CGFloat(page - target) * Self.pageStride - drag
        let v = abs(remaining) > 1 ? max(-12, min(12, velocity / remaining)) : 0
        let anim: Animation = Motion.reduced ? .easeOut(duration: 0.15)
            : .interpolatingSpring(mass: 1, stiffness: 240, damping: 28, initialVelocity: v)
        if target != page { Haptics.tick() }
        slide(anim) { page = target; drag = 0 }
    }

    /// Animates the row, keeping the neighbours drawn until it comes to rest.
    private func slide(_ animation: Animation? = nil, _ change: () -> Void) {
        sliding = true
        edgeFelt = false
        withAnimation(animation ?? Motion.soft, completionCriteria: .logicallyComplete) {
            change()
        } completion: {
            if drag == 0 { sliding = false }
        }
    }

    private func turn(to p: Int) {
        let next = min(max(p, 0), pages.count - 1)
        guard next != page else { return }
        slide { page = next; drag = 0 }
    }

    private var pageBar: some View {
        HStack(spacing: 6) {
            Button { turn(to: page - 1) } label: { Image(systemName: "chevron.left").font(.caption) }
                .opacity(page == 0 ? 0 : 1)
                .disabled(page == 0)
                .help("Or swipe with two fingers")
            Spacer()
            // One highlight glides to the page you're on and follows a swipe.
            ForEach(pages.indices, id: \.self) { i in
                let on = shownPage == i
                Button { turn(to: i) } label: {
                    Text(pages[i])
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(on ? .primary : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 3)
                        .background {
                            if on {
                                Capsule().fill(Color.primary.opacity(0.1))
                                    .matchedGeometryEffect(id: "pill", in: pill)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(PagePillButton())
            }
            Spacer()
            Button { turn(to: page + 1) } label: { Image(systemName: "chevron.right").font(.caption) }
                .opacity(page == pages.count - 1 ? 0 : 1)
                .disabled(page == pages.count - 1)
                .help("Or swipe with two fingers")
        }
        .buttonStyle(.lift)
        .controlSize(.small)
        .animation(Motion.bouncy, value: shownPage)
    }

    // MARK: receivers

    private var receiversSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionLabel("Send to")
                Spacer()
                if model.refreshing {
                    ProgressView().controlSize(.mini)
                } else {
                    Button { model.refreshTVs() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.lift).controlSize(.small)
                        .help("Look for TVs again")
                }
            }
            if model.selected.isEmpty, let place = model.suggestedPlace {
                placeCard(place)
            } else if model.selected.isEmpty, !model.lastGroupNames.isEmpty {
                lastGroupCard
            }
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
                                    if i > 0 { Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1).padding(.leading, 44) }
                                    ReceiverRow(model: model, tv: tv).id(tv.id)
                                }
                            }
                        }
                        .scrollIndicators(.automatic)
                        .frame(maxHeight: listHeight)
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

    /// "At Sanctuary?" when most of a saved place's TVs are visible.
    private func placeCard(_ p: Place) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse").foregroundStyle(Tokens.live)
            VStack(alignment: .leading, spacing: 1) {
                Text("At \(p.name)?").font(.caption.weight(.semibold))
                Text(model.tvNames(in: p).joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 6)
            Button("Connect") { model.connectPlace(p) }
                .buttonStyle(.borderedProminent).controlSize(.small)
        }
        .padding(10)
        .glass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
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
               text: "To show your screen, allow Screen Recording for AirPlay Splitter, then relaunch. Already switched on? macOS may be remembering an older copy: select AirPlay Splitter in that list, click −, then allow it again.") {
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
                .buttonStyle(.lift)
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
                            StatusDot(color: color, trigger: label)
                            Text(label).font(.caption).foregroundStyle(.secondary)
                                .contentTransition(.opacity)
                        }
                        .transition(.opacity)
                    }
                }
                Spacer(minLength: 8)
                Toggle(tv.name, isOn: isOn)
                    .toggleStyle(.tactileBare)
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
            .hoverRow()

            if needsPIN { pinEntry.transition(.opacity.combined(with: .move(edge: .top))) }
        }
        .animation(Motion.snappy, value: needsPIN)
        .animation(Motion.fade, value: status?.0)
    }

    private var pinEntry: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Enter the PIN shown on this TV.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                TextField("PIN", text: $pin)
                    .modifier(Field())
                    .font(.system(.body, design: .monospaced))
                    .frame(width: 96)
                    .focused($pinFocused)
                    .onSubmit(submit)
                Button("Pair", action: submit)
                    .buttonStyle(.borderedProminent)
                    .disabled(pin.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Cancel") { model.toggle(tv) }.buttonStyle(.lift)
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

/// Page names: a quick press-and-spring-back; the gliding pill shows which is on.
private struct PagePillButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.94 : 1)
            .animation(Motion.bouncy, value: configuration.isPressed)
    }
}

/// A status light that gives one small pop when the status changes (for
/// example when a TV starts showing). It never pulses on its own.
private struct StatusDot: View {
    let color: Color
    let trigger: String
    var body: some View {
        let peak: CGFloat = Motion.reduced ? 1 : 1.7
        return Circle().fill(color).frame(width: 6, height: 6)
            .keyframeAnimator(initialValue: CGFloat(1), trigger: trigger) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(peak, duration: 0.14)
                    SpringKeyframe(CGFloat(1), duration: 0.4, spring: .bouncy)
                }
            }
            .animation(Motion.fade, value: color)
    }
}
