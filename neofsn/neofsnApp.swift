import SwiftUI
import AppKit

@main
struct neofsnApp: App {

    init() {
        // macOS automatically renders a tab bar at the top of every window unless we opt out.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
    }
}
