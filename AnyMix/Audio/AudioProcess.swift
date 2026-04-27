import AppKit
import CoreAudio

/// Represents a group of related macOS processes from one app that produce audio.
/// For example, Chrome has a main process + multiple helper processes for tabs.
struct AudioProcessGroup: Identifiable {
    /// The root bundle ID (e.g. "com.google.Chrome" for all Chrome helpers).
    let bundleID: String

    /// Human-readable app name.
    let name: String

    /// App icon.
    let icon: NSImage

    /// All Core Audio object IDs for processes in this group.
    var objectIDs: [AudioObjectID]

    /// All PIDs in this group.
    var pids: Set<pid_t>

    var id: String { bundleID }

    /// Derive the root bundle ID from a full bundle ID.
    /// "com.google.Chrome.helper" → "com.google.Chrome"
    /// "com.apple.WebKit.GPU" → "com.apple.WebKit.GPU" (kept as-is, filtered later)
    static func rootBundleID(from bundleID: String) -> String {
        // Strip common helper suffixes
        let suffixes = [".helper", ".Helper", ".GPU", ".WebContent", ".Networking"]
        var root = bundleID
        for suffix in suffixes {
            if root.hasSuffix(suffix) {
                root = String(root.dropLast(suffix.count))
                break
            }
        }
        return root
    }
}
