import SwiftUI

@main
struct AnyMixApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No visible scenes — everything runs from the menu bar via AppDelegate.
        Settings { EmptyView() }
    }
}
