import Foundation
import Observation
import AppKit

/// Observable state for a single process in the UI.
@Observable
final class AppAudioState: Identifiable {
    let pid: pid_t
    let bundleID: String
    let name: String
    let icon: NSImage
    var volume: Float
    var isMuted: Bool
    var isActive: Bool
    var boostLevel: Int  // 1, 2, 3, or 4

    /// Effective gain = volume * boost. E.g. 80% at 3x = 2.4
    var effectiveVolume: Float {
        volume * Float(boostLevel)
    }

    var id: pid_t { pid }

    init(process: AudioProcess, volume: Float = 1.0, isMuted: Bool = false, boostLevel: Int = 1) {
        self.pid = process.pid
        self.bundleID = process.rootBundleID
        self.name = process.name
        self.icon = process.icon
        self.volume = volume
        self.isMuted = isMuted
        self.isActive = true
        self.boostLevel = boostLevel
    }
}

/// Main audio engine — one tap per process, each with its own slider.
@available(macOS 14.2, *)
@Observable
final class AudioEngine {
    private(set) var apps: [AppAudioState] = []
    private let discovery = ProcessDiscovery()
    private var taps: [pid_t: ProcessTap] = [:]
    private let volumeStore: VolumeStore
    private var removalTimers: [pid_t: Timer] = [:]

    var inactiveTimeout: TimeInterval = 30

    init(volumeStore: VolumeStore) {
        self.volumeStore = volumeStore

        discovery.onProcessListChanged = { [weak self] processes in
            self?.handleProcessListUpdate(processes)
        }

        let initial = discovery.discoverActiveProcesses()
        handleProcessListUpdate(initial)
    }

    deinit {
        stopAll()
    }

    // MARK: - Public API

    func setVolume(_ volume: Float, for pid: pid_t) {
        guard let app = apps.first(where: { $0.pid == pid }) else { return }
        app.volume = volume
        taps[pid]?.targetVolume = app.effectiveVolume
        volumeStore.setVolume(volume, for: app.bundleID)
    }

    func setBoost(_ level: Int, for pid: pid_t) {
        guard let app = apps.first(where: { $0.pid == pid }) else { return }
        app.boostLevel = level
        taps[pid]?.targetVolume = app.effectiveVolume
        volumeStore.setBoost(level, for: app.bundleID)
    }

    func cycleBoost(for pid: pid_t) {
        guard let app = apps.first(where: { $0.pid == pid }) else { return }
        let next = app.boostLevel >= 4 ? 1 : app.boostLevel + 1
        setBoost(next, for: pid)
    }

    func setMuted(_ muted: Bool, for pid: pid_t) {
        guard let app = apps.first(where: { $0.pid == pid }) else { return }
        app.isMuted = muted
        taps[pid]?.isMuted = muted
        volumeStore.setMuted(muted, for: app.bundleID)
    }

    func toggleMute(for pid: pid_t) {
        guard let app = apps.first(where: { $0.pid == pid }) else { return }
        setMuted(!app.isMuted, for: pid)
    }

    var allMuted: Bool {
        apps.allSatisfy { $0.isMuted } && !apps.isEmpty
    }

    func refresh() {
        let processes = discovery.discoverActiveProcesses()
        handleProcessListUpdate(processes)
    }

    // MARK: - Internal

    private func handleProcessListUpdate(_ processes: [AudioProcess]) {
        let currentPIDs = Set(processes.map(\.pid))
        let existingPIDs = Set(apps.map(\.pid))

        // New processes
        for process in processes where !existingPIDs.contains(process.pid) {
            addProcess(process)
        }

        // Disappeared processes
        for app in apps where !currentPIDs.contains(app.pid) {
            if app.isActive {
                markInactive(app)
            }
        }

        // Reappeared processes
        for app in apps where currentPIDs.contains(app.pid) && !app.isActive {
            cancelRemoval(app)
        }
    }

    private func addProcess(_ process: AudioProcess) {
        let savedVolume = volumeStore.volume(for: process.rootBundleID)
        let savedMuted = volumeStore.isMuted(for: process.rootBundleID)
        let savedBoost = volumeStore.boost(for: process.rootBundleID)

        let state = AppAudioState(process: process, volume: savedVolume, isMuted: savedMuted, boostLevel: savedBoost)

        let tap = ProcessTap(pid: process.pid)
        tap.targetVolume = state.effectiveVolume
        tap.isMuted = savedMuted

        do {
            try tap.start(objectID: process.objectID)
            taps[process.pid] = tap
        } catch {
            AnyMixLogger.log("Failed to start tap for \(process.name) (pid \(process.pid)): \(error)")
        }

        apps.append(state)
    }

    private func markInactive(_ app: AppAudioState) {
        app.isActive = false

        // 0 = never remove inactive apps
        guard inactiveTimeout > 0 else { return }

        let timer = Timer.scheduledTimer(withTimeInterval: inactiveTimeout, repeats: false) { [weak self] _ in
            self?.removeProcess(app.pid)
        }
        removalTimers[app.pid] = timer
    }

    private func cancelRemoval(_ app: AppAudioState) {
        app.isActive = true
        removalTimers[app.pid]?.invalidate()
        removalTimers.removeValue(forKey: app.pid)
    }

    private func removeProcess(_ pid: pid_t) {
        taps[pid]?.stop()
        taps.removeValue(forKey: pid)
        removalTimers[pid]?.invalidate()
        removalTimers.removeValue(forKey: pid)
        apps.removeAll { $0.pid == pid }
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
