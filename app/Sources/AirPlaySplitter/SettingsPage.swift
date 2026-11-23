import SwiftUI

/// The Settings page: how the stream behaves.
struct SettingsPage: View {
    @ObservedObject var model: SplitterModel

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: Tokens.gap) {
                StreamCard(model: model)
            }
        }
        .scrollIndicators(.automatic)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipShape(RoundedRectangle(cornerRadius: Tokens.radius, style: .continuous))
    }
}

/// Slides / Balanced / Video: how often a full keyframe goes to the TVs.
private struct StreamCard: View {
    @ObservedObject var model: SplitterModel
    @Namespace private var pick

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(0.75))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.primary.opacity(0.1)))
                Text("Stream").font(.system(size: 12, weight: .semibold))
            }
            // Three round choices, like Control Center; the chosen one fills.
            HStack(spacing: 8) {
                ForEach(SplitterModel.StreamMode.allCases) { mode in
                    let on = model.streamMode == mode
                    Button {
                        withAnimation(Motion.bouncy) { model.streamMode = mode }
                        Haptics.tick()
                    } label: {
                        VStack(spacing: 6) {
                            OrbIcon(symbol: mode.symbol, on: on, size: 36)
                            Text(mode.title).font(.system(size: 11, weight: on ? .semibold : .regular))
                                .foregroundStyle(on ? .primary : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
            Text(model.streamMode.detail)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .contentTransition(.opacity)
                .animation(Motion.fade, value: model.streamMode)
            if !model.selected.isEmpty {
                Label("Changing this reconnects the TVs for a moment.", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .tile()
    }
}
