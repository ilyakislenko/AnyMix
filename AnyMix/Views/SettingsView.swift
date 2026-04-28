import SwiftUI
import ServiceManagement

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            SavedVolumesTab()
                .tabItem {
                    Label("Saved Volumes", systemImage: "speaker.wave.2")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 420, height: 280)
    }
}

// MARK: - General Tab

struct GeneralTab: View {
    @State private var launchAtLogin = false
    @AppStorage("showInactiveApps") private var showInactiveApps = true
    @AppStorage("inactiveTimeout") private var inactiveTimeout: Double = 30

    var body: some View {
        Form {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onAppear {
                    launchAtLogin = (SMAppService.mainApp.status == .enabled)
                }
                .onChange(of: launchAtLogin) { _, newValue in
                    do {
                        if newValue {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        print("Launch at login error: \(error)")
                        launchAtLogin = (SMAppService.mainApp.status == .enabled)
                    }
                }

            Toggle("Show inactive apps in popover", isOn: $showInactiveApps)

            HStack {
                Text("Remove inactive apps after")
                TextField("", value: $inactiveTimeout, format: .number)
                    .frame(width: 50)
                    .textFieldStyle(.roundedBorder)
                Text("sec (0 = never)")
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Saved Volumes Tab

struct SavedVolumesTab: View {
    @Environment(VolumeStore.self) private var volumeStore

    var body: some View {
        VStack {
            if volumeStore.savedVolumes.isEmpty {
                Text("No saved volume settings")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(volumeStore.savedVolumes.keys.sorted()), id: \.self) { bundleID in
                        if let appVolume = volumeStore.savedVolumes[bundleID] {
                            HStack {
                                Text(bundleID)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                Spacer()
                                Text("\(Int(appVolume.volume * 100))%")
                                    .foregroundStyle(.secondary)
                                    .font(.system(size: 12, design: .monospaced))
                                if appVolume.isMuted {
                                    Image(systemName: "speaker.slash.fill")
                                        .foregroundStyle(.red)
                                        .font(.system(size: 10))
                                }
                                Button {
                                    volumeStore.remove(for: bundleID)
                                } label: {
                                    Image(systemName: "trash")
                                        .foregroundStyle(.secondary)
                                        .font(.system(size: 10))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("Reset All") {
                    volumeStore.resetAll()
                }
                .disabled(volumeStore.savedVolumes.isEmpty)
            }
            .padding()
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "speaker.wave.3.fill")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text("AnyMix")
                .font(.title2.bold())

            Text("Per-App Volume Mixer for macOS")
                .foregroundStyle(.secondary)

            Text("Version 0.1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 200)

            Button("View on GitHub") {
                if let url = URL(string: "https://github.com/AnyMix/AnyMix") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)

            Text("MIT License")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
