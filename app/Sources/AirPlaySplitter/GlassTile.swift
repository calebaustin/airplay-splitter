import SwiftUI
import AppKit

/// The one glass material for every tile. The menu window has no background,
/// so each tile must carry its own: Liquid Glass on macOS 26, and on older
/// systems a frosted blur of whatever is behind the window (the desktop),
/// with a thin light rim like Control Center's modules.
struct TileGlassStyle<S: InsettableShape>: ViewModifier {
    let shape: S
    var interactive = false

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            // A light tint in the window colour keeps text readable over busy
            // windows behind the menu, the way Control Center's modules do.
            let tint = Color(nsColor: .windowBackgroundColor).opacity(0.28)
            content.glassEffect(interactive ? .regular.tint(tint).interactive() : .regular.tint(tint), in: shape)
        } else {
            content
                .background(BehindWindowBlur().clipShape(shape))
                .overlay(shape.strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
    }
}

extension View {
    func tileGlass<S: InsettableShape>(_ shape: S, interactive: Bool = false) -> some View {
        modifier(TileGlassStyle(shape: shape, interactive: interactive))
    }
    /// A rounded tile in the shared corner size.
    func tile(interactive: Bool = false) -> some View {
        tileGlass(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous), interactive: interactive)
    }
}

/// Frosted blur of what's behind the window (macOS 14 and 15).
private struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .hudWindow
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// Control Center's round icon: white with a coloured glyph when on in dark
/// mode, coloured with a white glyph when on in light mode, and a soft
/// translucent circle when off.
struct OrbIcon: View {
    let symbol: String
    let on: Bool
    var tint: Color = .accentColor
    var size: CGFloat = 34
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .foregroundStyle(on ? (dark ? tint : .white) : Color.primary.opacity(0.85))
            .frame(width: size, height: size)
            .background(Circle().fill(on ? (dark ? Color.white : tint) : Color.primary.opacity(0.12)))
            .animation(Motion.bouncy, value: on)
    }
}
