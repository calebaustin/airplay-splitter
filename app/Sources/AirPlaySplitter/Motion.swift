import SwiftUI
import AppKit

// Motion and feel, following the Modern UI Jumpstart rules adapted for a
// menu-bar app: springs that settle and stop, one hover-and-press style for
// every small button, switches that feel physical, nothing that loops while
// idle, and everything calmer when Reduce Motion is on.

enum Motion {
    /// The system setting "Reduce motion" (Accessibility > Display).
    @MainActor static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// Presses, hovers, small toggles.
    @MainActor static var snappy: Animation { reduced ? .easeOut(duration: 0.12) : .spring(duration: 0.42, bounce: 0.15) }
    /// A switch knob landing, a pill arriving: a little overshoot.
    @MainActor static var bouncy: Animation { reduced ? .easeOut(duration: 0.12) : .spring(duration: 0.5, bounce: 0.32) }
    /// Panels and pages settling.
    @MainActor static var soft: Animation { reduced ? .easeOut(duration: 0.15) : .spring(duration: 0.55, bounce: 0.1) }
    /// Color-only changes (always on, even with Reduce Motion).
    static let fade: Animation = .easeOut(duration: 0.16)
}

/// Trackpad taps you can feel (Force Touch trackpads only; silent elsewhere).
enum Haptics {
    /// A switch flipping, a page landing.
    static func tick() {
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
    /// Lining up with something (page edge reached).
    static func align() {
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
    }
}

// MARK: switch

/// A switch that feels like a real one: the knob stretches while you hold it,
/// springs across with a little overshoot, can be dragged, and taps the
/// trackpad when it flips. VoiceOver still sees a standard switch.
struct TactileSwitch: ToggleStyle {
    enum Size { case regular, small }
    var size: Size = .small
    /// Custom styles don't get .labelsHidden(), so say it here.
    var showsLabel = true

    func makeBody(configuration: Configuration) -> some View {
        SwitchBody(configuration: configuration, size: size, showsLabel: showsLabel)
    }

    private struct SwitchBody: View {
        let configuration: Configuration
        let size: Size
        let showsLabel: Bool
        @Environment(\.isEnabled) private var enabled
        @State private var pressed = false
        @State private var hovering = false
        @State private var dragFlipped = false

        private var w: CGFloat { size == .regular ? 38 : 32 }
        private var h: CGFloat { size == .regular ? 22 : 18 }
        private var inset: CGFloat { 2 }
        private var knob: CGFloat { h - inset * 2 }
        private var stretch: CGFloat { pressed && !Motion.reduced ? knob * 0.28 : 0 }

        var body: some View {
            HStack(spacing: 8) {
                if showsLabel { configuration.label }
                ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                    Capsule()
                        .fill(configuration.isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.22 : 0.16)))
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(configuration.isOn ? 0 : 0.06), lineWidth: 0.5))
                    Capsule()
                        .fill(.white)
                        .shadow(color: .black.opacity(0.22), radius: pressed ? 2.5 : 1.5, y: 1)
                        .frame(width: knob + stretch, height: knob)
                        .padding(inset)
                }
                .frame(width: w, height: h)
                .brightness(hovering && configuration.isOn ? 0.04 : 0)
                .animation(Motion.bouncy, value: configuration.isOn)
                .animation(Motion.snappy, value: pressed)
                .animation(Motion.fade, value: hovering)
                .contentShape(Capsule())
                .onHover { hovering = $0 && enabled }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            guard enabled else { return }
                            pressed = true
                            // Dragging the knob across flips it, like a real switch.
                            let wantsOn = g.translation.width > 6
                            let wantsOff = g.translation.width < -6
                            if !dragFlipped, (wantsOn && !configuration.isOn) || (wantsOff && configuration.isOn) {
                                dragFlipped = true
                                flip()
                            }
                        }
                        .onEnded { g in
                            guard enabled else { return }
                            if !dragFlipped, abs(g.translation.width) < 6, abs(g.translation.height) < 10 { flip() }
                            pressed = false
                            dragFlipped = false
                        }
                )
            }
            .opacity(enabled ? 1 : 0.45)
            .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
        }

        private func flip() {
            configuration.isOn.toggle()
            Haptics.tick()
        }
    }
}

extension ToggleStyle where Self == TactileSwitch {
    static var tactile: TactileSwitch { TactileSwitch() }
    static var tactileRegular: TactileSwitch { TactileSwitch(size: .regular) }
    /// No visible label (the label is still read by VoiceOver).
    static var tactileBare: TactileSwitch { TactileSwitch(showsLabel: false) }
    static var tactileBareRegular: TactileSwitch { TactileSwitch(size: .regular, showsLabel: false) }
}

// MARK: buttons

/// The one hover-and-press style for small text and icon buttons: on hover a
/// soft pill appears and the button lifts 1pt; pressing sinks it to 94% and it
/// springs back. Text and icon never fade out on hover.
struct LiftButton: ButtonStyle {
    var tint: Color? = nil

    func makeBody(configuration: Configuration) -> some View {
        LiftBody(configuration: configuration, tint: tint)
    }

    private struct LiftBody: View {
        let configuration: Configuration
        let tint: Color?
        @Environment(\.isEnabled) private var enabled
        @State private var hovering = false

        var body: some View {
            configuration.label
                .foregroundStyle(tint.map { AnyShapeStyle($0) } ?? AnyShapeStyle(hovering ? .primary : .secondary))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(Color.primary.opacity(configuration.isPressed ? 0.14 : hovering ? 0.08 : 0)))
                .contentShape(Capsule())
                .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.94 : 1)
                .offset(y: hovering && !configuration.isPressed && !Motion.reduced ? -1 : 0)
                .opacity(enabled ? 1 : 0.4)
                .animation(Motion.bouncy, value: configuration.isPressed)
                .animation(Motion.snappy, value: hovering)
                .onHover { hovering = $0 && enabled }
        }
    }
}

extension ButtonStyle where Self == LiftButton {
    static var lift: LiftButton { LiftButton() }
}

// MARK: rows

/// A faint highlight under a row while the pointer is over it.
struct HoverRow: ViewModifier {
    var radius: CGFloat = Tokens.rowRadius
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.05 : 0))
                    .padding(.horizontal, 4)
            )
            .onHover { h in withAnimation(Motion.fade) { hovering = h } }
    }
}

extension View {
    func hoverRow() -> some View { modifier(HoverRow()) }
}
