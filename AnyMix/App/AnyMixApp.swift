import SwiftUI

@main
struct AnyMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(appDelegate.volumeStore)
        }
    }
}
