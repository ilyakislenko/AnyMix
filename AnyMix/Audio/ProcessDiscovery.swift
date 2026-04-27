import CoreAudio
import AppKit

/// Discovers and monitors macOS processes that are producing audio output.
/// Groups related processes (e.g. Chrome + Chrome helpers) into one entry.
final class ProcessDiscovery: @unchecked Sendable {

    var onProcessListChanged: (([AudioProcessGroup]) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.anymix.processDiscovery")

    /// Bundle IDs (or root bundle IDs) to always exclude.
    private static let excludedBundleIDs: Set<String> = [
        "com.anymix.app",
        "com.apple.AirPlayXPCHelper",
        "com.apple.audio.SandboxHelper",
        "com.apple.coreaudiod",
        "com.apple.audio.DriverHelper",
        "com.apple.avconferenced",
        "com.apple.controlcenter",
        "com.apple.cmio.ContinuityCaptureAgent",
        "com.apple.universalaccessd",
        "com.apple.CoreSpeech",
        "com.apple.loginwindow",
        "com.apple.PowerChime",
        "com.apple.assistantd",
        "com.apple.TelephonyUtilities",
        "com.apple.SiriNCService",
        "com.apple.WebKit",
        "com.apple.mediaremoted",
        "systemsoundserverd",
    ]

    init() {
        installListener()
    }

    deinit {
        removeListener()
    }

    /// Discover active audio processes, grouped by root app.
    func discoverActiveProcesses() -> [AudioProcessGroup] {
        let processIDs = getProcessObjectList()
        let ownPID = ProcessInfo.processInfo.processIdentifier

        // Collect all audio-producing processes
        struct RawProcess {
            let objectID: AudioObjectID
            let pid: pid_t
            let bundleID: String
        }

        var rawProcesses: [RawProcess] = []

        for objectID in processIDs {
            guard let pid = getPID(objectID), pid > 0, pid != ownPID else { continue }

            let bundleID = getBundleID(objectID)
            guard !bundleID.isEmpty else { continue }

            let rootID = AudioProcessGroup.rootBundleID(from: bundleID)
            guard !Self.excludedBundleIDs.contains(rootID) && !Self.excludedBundleIDs.contains(bundleID) else { continue }

            rawProcesses.append(RawProcess(objectID: objectID, pid: pid, bundleID: bundleID))
        }

        // Group by root bundle ID
        var groups: [String: (objectIDs: [AudioObjectID], pids: Set<pid_t>, anyActive: Bool)] = [:]

        for raw in rawProcesses {
            let rootID = AudioProcessGroup.rootBundleID(from: raw.bundleID)
            var group = groups[rootID] ?? (objectIDs: [], pids: [], anyActive: false)
            group.objectIDs.append(raw.objectID)
            group.pids.insert(raw.pid)
            if isRunningOutput(raw.objectID) {
                group.anyActive = true
            }
            groups[rootID] = group
        }

        // Only include groups where at least one process is actively outputting
        var result: [AudioProcessGroup] = []
        for (rootBundleID, group) in groups {
            guard group.anyActive else { continue }

            let (name, icon) = appInfo(rootBundleID: rootBundleID, pids: group.pids)

            result.append(AudioProcessGroup(
                bundleID: rootBundleID,
                name: name,
                icon: icon,
                objectIDs: group.objectIDs,
                pids: group.pids
            ))
        }

        return result.sorted { $0.name < $1.name }
    }

    // MARK: - Core Audio Queries

    private func getProcessObjectList() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var objectIDs = [AudioObjectID](repeating: 0, count: count)
        AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &objectIDs
        )
        return objectIDs
    }

    private func isRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var isRunning: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &isRunning)
        return isRunning != 0
    }

    private func getPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid)
        guard status == noErr, pid > 0 else { return nil }
        return pid
    }

    private func getBundleID(_ objectID: AudioObjectID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfStr)
        guard status == noErr, let cf = cfStr else { return "" }
        return cf.takeUnretainedValue() as String
    }

    /// Resolve app name and icon from the root bundle ID.
    /// Tries to find the running app first, then falls back to bundle lookup.
    private func appInfo(rootBundleID: String, pids: Set<pid_t>) -> (String, NSImage) {
        let defaultIcon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()

        // Try to find a running app matching the root bundle ID
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == rootBundleID {
                let name = app.localizedName ?? rootBundleID
                let icon = app.icon ?? defaultIcon
                return (name, icon)
            }
        }

        // Try to find by any of the PIDs
        for pid in pids {
            if let app = NSRunningApplication(processIdentifier: pid) {
                if let appBundle = app.bundleIdentifier,
                   AudioProcessGroup.rootBundleID(from: appBundle) == rootBundleID {
                    let name = app.localizedName ?? rootBundleID
                    let icon = app.icon ?? defaultIcon
                    return (name, icon)
                }
            }
        }

        // Last resort: try to get the app name from the bundle ID
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: rootBundleID) {
            let name = FileManager.default.displayName(atPath: appURL.path)
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            return (name, icon)
        }

        return (rootBundleID, defaultIcon)
    }

    // MARK: - Listener

    private func installListener() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let processes = self.discoverActiveProcesses()
            DispatchQueue.main.async {
                self.onProcessListChanged?(processes)
            }
        }
        self.listenerBlock = block

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
    }

    private func removeListener() {
        guard let block = listenerBlock else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            listenerQueue,
            block
        )
    }
}
