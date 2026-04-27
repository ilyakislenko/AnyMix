import Foundation
import Observation

/// Persists per-app volume settings using UserDefaults.
@Observable
final class VolumeStore {
    private let defaults = UserDefaults.standard
    private let storageKey = "com.anymix.savedVolumes"

    struct AppVolume: Codable {
        var volume: Float
        var isMuted: Bool
    }

    /// In-memory cache of saved volumes keyed by bundle ID.
    private(set) var savedVolumes: [String: AppVolume] = [:]

    init() {
        load()
    }

    func volume(for bundleID: String) -> Float {
        savedVolumes[bundleID]?.volume ?? 1.0
    }

    func isMuted(for bundleID: String) -> Bool {
        savedVolumes[bundleID]?.isMuted ?? false
    }

    func setVolume(_ volume: Float, for bundleID: String) {
        if savedVolumes[bundleID] == nil {
            savedVolumes[bundleID] = AppVolume(volume: volume, isMuted: false)
        } else {
            savedVolumes[bundleID]?.volume = volume
        }
        save()
    }

    func setMuted(_ muted: Bool, for bundleID: String) {
        if savedVolumes[bundleID] == nil {
            savedVolumes[bundleID] = AppVolume(volume: 1.0, isMuted: muted)
        } else {
            savedVolumes[bundleID]?.isMuted = muted
        }
        save()
    }

    func resetAll() {
        savedVolumes.removeAll()
        save()
    }

    func remove(for bundleID: String) {
        savedVolumes.removeValue(forKey: bundleID)
        save()
    }

    private func load() {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: AppVolume].self, from: data)
        else { return }
        savedVolumes = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(savedVolumes) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
