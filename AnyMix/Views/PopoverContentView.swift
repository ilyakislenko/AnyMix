import SwiftUI

struct PopoverContentView: View {
    let audioEngine: AudioEngine

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("AnyMix")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: openSettings) {
                    Image(systemName: "gearshape")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider()

            if audioEngine.apps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "speaker.slash")
                        .font(.system(size: 28))
                        .foregroundStyle(.tertiary)
                    Text("No apps playing audio")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, 40)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(audioEngine.apps) { app in
                            AppVolumeRow(
                                app: app,
                                onVolumeChange: { volume in
                                    audioEngine.setVolume(volume, for: app.pid)
                                },
                                onToggleMute: {
                                    audioEngine.toggleMute(for: app.pid)
                                }
                            )
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 320, height: max(180, CGFloat(audioEngine.apps.count) * 40 + 80))
        .frame(maxHeight: 400)
    }

    private func openSettings() {
        NotificationCenter.default.post(name: .openSettingsNotification, object: nil)
    }
}

extension Notification.Name {
    static let openSettingsNotification = Notification.Name("com.anymix.openSettings")
}
