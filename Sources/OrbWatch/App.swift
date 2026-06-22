import SwiftUI
import AppKit

/// Ensures the app shows a real window + Dock icon even when launched from a
/// SwiftPM build (which otherwise starts as an accessory/agent).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.applicationIconImage = AppIcon.image(512)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool {
        true
    }
}

struct OrbWatchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        WindowGroup("OrbWatch") {
            ContentView()
        }
        .defaultSize(width: 980, height: 600)
        .windowToolbarStyle(.unified)
    }
}
