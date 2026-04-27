import SwiftUI

struct AppVolumeRow: View {
    let app: AppAudioState
    let onVolumeChange: (Float) -> Void
    let onToggleMute: () -> Void

    @State private var sliderValue: Double

    init(app: AppAudioState, onVolumeChange: @escaping (Float) -> Void, onToggleMute: @escaping () -> Void) {
        self.app = app
        self.onVolumeChange = onVolumeChange
        self.onToggleMute = onToggleMute
        self._sliderValue = State(initialValue: Double(app.volume))
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 24, height: 24)
                .opacity(app.isActive ? 1.0 : 0.5)

            Text(app.name)
                .font(.system(size: 12))
                .lineLimit(1)
                .frame(width: 70, alignment: .leading)
                .opacity(app.isActive ? 1.0 : 0.5)

            Slider(value: $sliderValue, in: 0...1)
                .onChange(of: sliderValue) { _, newValue in
                    onVolumeChange(Float(newValue))
                }
                .disabled(app.isMuted)

            Text("\(Int(sliderValue * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .trailing)

            Button(action: onToggleMute) {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : volumeIcon)
                    .foregroundStyle(app.isMuted ? .red : .secondary)
                    .frame(width: 16)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onChange(of: app.volume) { _, newValue in
            sliderValue = Double(newValue)
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
