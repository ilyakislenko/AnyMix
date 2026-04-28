import CoreAudio
import AppKit

/// Discovers and monitors macOS processes that are producing audio output.
final class ProcessDiscovery: @unchecked Sendable {

    var onProcessListChanged: (([AudioProcess]) -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.anymix.processDiscovery")

    /// Bundle IDs (exact or root) to always exclude.
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

    /// Discover active audio processes. Each process gets its own entry.
    func discoverActiveProcesses() -> [AudioProcess] {
        let processIDs = getProcessObjectList()
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var seen = Set<pid_t>()
        var result: [AudioProcess] = []

        for objectID in processIDs {
            guard isRunningOutput(objectID) else { continue }
            guard let pid = getPID(objectID), pid > 0, pid != ownPID else { continue }
            guard seen.insert(pid).inserted else { continue }

            let bundleID = getBundleID(objectID)
            guard !bundleID.isEmpty else { continue }

            let rootBundleID = AudioProcess.deriveRootBundleID(from: bundleID)
            guard !Self.excludedBundleIDs.contains(rootBundleID),
                  !Self.excludedBundleIDs.contains(bundleID) else { continue }

            let (name, icon) = appInfo(rootBundleID: rootBundleID, pid: pid)

            result.append(AudioProcess(
                objectID: objectID,
                pid: pid,
                bundleID: bundleID,
                rootBundleID: rootBundleID,
                name: name,
                icon: icon
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

    /// Resolve app name and icon. Uses the root bundle ID to find the parent app.
    private func appInfo(rootBundleID: String, pid: pid_t) -> (String, NSImage) {
        let defaultIcon = NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()

        // Try to find the running app by root bundle ID
        for app in NSWorkspace.shared.runningApplications {
            if app.bundleIdentifier == rootBundleID {
                let name = app.localizedName ?? rootBundleID
                let icon = app.icon ?? defaultIcon
                return (name, icon)
            }
        }

        // Try by PID
        if let app = NSRunningApplication(processIdentifier: pid) {
            let name = app.localizedName ?? rootBundleID
            let icon = app.icon ?? defaultIcon
            return (name, icon)
        }

        // Try NSWorkspace bundle lookup
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
