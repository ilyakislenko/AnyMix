import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var eventMonitor: Any?

    let volumeStore = VolumeStore()
    private(set) var audioEngine: AudioEngine!

    func applicationDidFinishLaunching(_ notification: Notification) {
        audioEngine = AudioEngine(volumeStore: volumeStore)

        // Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 300)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverContentView(audioEngine: audioEngine)
        )
        self.popover = popover

        // Create status bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            button.image = NSImage(
                systemSymbolName: "speaker.wave.2.fill",
                accessibilityDescription: "AnyMix"
            )
            button.image?.isTemplate = true
            button.action = #selector(togglePopover(_:))
            button.target = self
        }

        // Listen for settings open requests
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(openSettings),
            name: .openSettingsNotification,
            object: nil
        )

        // Global click monitor to dismiss popover
        eventMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            DispatchQueue.main.async {
                if let popover = self?.popover, popover.isShown {
                    popover.performClose(nil)
                }
            }
        }

        // Periodic refresh of process list
        Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.audioEngine.refresh()
                self?.updateStatusIcon()
            }
        }
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            audioEngine.refresh()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.becomeKey()
        }
    }

    @objc private func openSettings() {
        popover.performClose(nil)

        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        // Observe when settings window closes to go back to accessory mode
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            _ = self // prevent warning
            if let settingsWindow = NSApp.windows.first(where: {
                $0.identifier?.rawValue.contains("settings") == true ||
                $0.title.lowercased().contains("settings") ||
                $0.title.lowercased().contains("preferences")
            }) {
                NotificationCenter.default.addObserver(
                    forName: NSWindow.willCloseNotification,
                    object: settingsWindow,
                    queue: .main
                ) { _ in
                    NSApp.setActivationPolicy(.accessory)
                }
            }
        }
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let iconName = audioEngine.allMuted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        button.image = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: "AnyMix"
        )
        button.image?.isTemplate = true
    }
}
