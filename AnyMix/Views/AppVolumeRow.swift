import SwiftUI

struct AppVolumeRow: View {
    let app: AppAudioState
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void
    let onCycleBoost: () -> Void

    @State private var sliderValue: Double

    init(app: AppAudioState,
         onVolumeChange: @escaping (Float) -> Void,
         onToggleMute: @escaping () -> Void,
         onCycleBoost: @escaping () -> Void)
    {
        self.app = app
        self.onVolumeChange = onVolumeChange
        self.onToggleMute = onToggleMute
        self.onCycleBoost = onCycleBoost
        self._sliderValue = State(initialValue: Double(app.volume))
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(app.isActive ? 1.0 : 0.5)

            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 60, alignment: .leading)
                .opacity(app.isActive ? 1.0 : 0.5)

            Slider(value: $sliderValue, in: 0...1)
                .onChange(of: sliderValue) { _, newValue in
                    onVolumeChange(Float(newValue))
                }
                .disabled(app.isMuted)

            // Effective percentage (volume × boost)
            Text(effectiveLabel)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 36, alignment: .trailing)

            // Boost button
            Button(action: onCycleBoost) {
                Text("\(app.boostLevel)x")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(app.boostLevel > 1 ? .white : .secondary)
                    .frame(width: 22, height: 16)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(app.boostLevel > 1 ? boostColor : Color.clear)
                    )
            }
            .buttonStyle(.plain)

            // Mute button
            Button(action: onToggleMute) {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : volumeIcon)
                    .foregroundStyle(app.isMuted ? .red : .secondary)
                    .frame(width: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onChange(of: app.volume) { _, newValue in
            sliderValue = Double(newValue)
        }
    }

    private var effectiveLabel: String {
        let pct = Int(sliderValue * 100.0 * Double(app.boostLevel))
        return "\(pct)%"
    }

    private var boostColor: Color {
        switch app.boostLevel {
        case 2: return .blue
        case 3: return .orange
        case 4: return .red
        default: return .clear
        }
    }

    private var volumeIcon: String {
        if sliderValue == 0 {
            return "speaker.fill"
        } else if sliderValue < 0.33 {
            return "speaker.wave.1.fill"
        } else if sliderValue < 0.66 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
