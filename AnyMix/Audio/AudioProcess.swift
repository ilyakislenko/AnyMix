import AppKit
import CoreAudio

/// Represents a single macOS process that produces audio.
struct AudioProcess: Identifiable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let rootBundleID: String
    let name: String
    let icon: NSImage

    /// Unique ID — use pid so each process gets its own slider.
    var id: pid_t { pid }

    /// Derive the root bundle ID from a full bundle ID.
    /// "com.google.Chrome.helper" → "com.google.Chrome"
    static func deriveRootBundleID(from bundleID: String) -> String {
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
