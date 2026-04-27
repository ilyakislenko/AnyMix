import Foundation
import Observation
import AppKit

/// Observable state for a single app in the UI.
@Observable
final class AppAudioState: Identifiable {
    let bundleID: String
    let name: String
    let icon: NSImage
    var volume: Float
    var isMuted: Bool
    var isActive: Bool

    var id: String { bundleID }

    init(group: AudioProcessGroup, volume: Float = 1.0, isMuted: Bool = false) {
        self.bundleID = group.bundleID
        self.name = group.name
        self.icon = group.icon
        self.volume = volume
        self.isMuted = isMuted
        self.isActive = true
    }
}

/// Main audio engine that connects process discovery, taps, and persistence.
@available(macOS 14.2, *)
@Observable
final class AudioEngine {
    private(set) var apps: [AppAudioState] = []
    private let discovery = ProcessDiscovery()
    private var taps: [String: ProcessTap] = [:]  // keyed by bundle ID
    private let volumeStore: VolumeStore
    private var removalTimers: [String: Timer] = [:]

    var inactiveTimeout: TimeInterval = 30

    init(volumeStore: VolumeStore) {
        self.volumeStore = volumeStore

        discovery.onProcessListChanged = { [weak self] groups in
            self?.handleProcessListUpdate(groups)
        }

        let initial = discovery.discoverActiveProcesses()
        handleProcessListUpdate(initial)
    }

    deinit {
        stopAll()
    }

    // MARK: - Public API

    func setVolume(_ volume: Float, for bundleID: String) {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else { return }
        app.volume = volume
        taps[bundleID]?.targetVolume = volume
        volumeStore.setVolume(volume, for: bundleID)
    }

    func setMuted(_ muted: Bool, for bundleID: String) {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else { return }
        app.isMuted = muted
        taps[bundleID]?.isMuted = muted
        volumeStore.setMuted(muted, for: bundleID)
    }

    func toggleMute(for bundleID: String) {
        guard let app = apps.first(where: { $0.bundleID == bundleID }) else { return }
        setMuted(!app.isMuted, for: bundleID)
    }

    var allMuted: Bool {
        apps.allSatisfy { $0.isMuted } && !apps.isEmpty
    }

    func refresh() {
        let groups = discovery.discoverActiveProcesses()
        handleProcessListUpdate(groups)
    }

    // MARK: - Internal

    private func handleProcessListUpdate(_ groups: [AudioProcessGroup]) {
        let currentBundleIDs = Set(groups.map(\.bundleID))
        let existingBundleIDs = Set(apps.map(\.bundleID))

        // New apps
        for group in groups where !existingBundleIDs.contains(group.bundleID) {
            addGroup(group)
        }

        // Updated apps (process list may have changed — recreate tap)
        for group in groups where existingBundleIDs.contains(group.bundleID) {
            updateGroup(group)
        }

        // Disappeared apps
        for app in apps where !currentBundleIDs.contains(app.bundleID) {
            if app.isActive {
                markInactive(app)
            }
        }

        // Reappeared apps
        for app in apps where currentBundleIDs.contains(app.bundleID) && !app.isActive {
            cancelRemoval(app)
        }
    }

    private func addGroup(_ group: AudioProcessGroup) {
        let savedVolume = volumeStore.volume(for: group.bundleID)
        let savedMuted = volumeStore.isMuted(for: group.bundleID)

        let state = AppAudioState(group: group, volume: savedVolume, isMuted: savedMuted)

        let tap = ProcessTap(bundleID: group.bundleID)
        tap.targetVolume = savedVolume
        tap.isMuted = savedMuted

        do {
            try tap.start(objectIDs: group.objectIDs)
            taps[group.bundleID] = tap
        } catch {
            AnyMixLogger.log("Failed to start tap for \(group.bundleID): \(error)")
        }

        apps.append(state)
    }

    private func updateGroup(_ group: AudioProcessGroup) {
        // If the set of object IDs changed, recreate the tap
        guard let existingTap = taps[group.bundleID] else { return }
        // For now, just let the existing tap run.
        // Recreating on every refresh would be disruptive.
        // TODO: track objectIDs and recreate only when they change
        _ = existingTap
    }

    private func markInactive(_ app: AppAudioState) {
        app.isActive = false

        let timer = Timer.scheduledTimer(withTimeInterval: inactiveTimeout, repeats: false) { [weak self] _ in
            self?.removeApp(app.bundleID)
        }
        removalTimers[app.bundleID] = timer
    }

    private func cancelRemoval(_ app: AppAudioState) {
        app.isActive = true
        removalTimers[app.bundleID]?.invalidate()
        removalTimers.removeValue(forKey: app.bundleID)
    }

    private func removeApp(_ bundleID: String) {
        taps[bundleID]?.stop()
        taps.removeValue(forKey: bundleID)
        removalTimers[bundleID]?.invalidate()
        removalTimers.removeValue(forKey: bundleID)
        apps.removeAll { $0.bundleID == bundleID }
    }

    private func stopAll() {
        for (_, tap) in taps { tap.stop() }
        taps.removeAll()
        for (_, timer) in removalTimers { timer.invalidate() }
        removalTimers.removeAll()
    }
}

// MARK: - Logger

enum AnyMixLogger {
    private static let logDir: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/AnyMix")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let logFile: URL = {
        logDir.appendingPathComponent("anymix.log")
    }()

    static func log(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "[\(timestamp)] \(message)\n"
        print(line, terminator: "")

        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: logFile.path) {
                if let handle = try? FileHandle(forWritingTo: logFile) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try? data.write(to: logFile)
            }
        }
    }
}
