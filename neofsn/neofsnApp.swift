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
                .background(WindowConfigurator())
        }
        .defaultSize(width: 1280, height: 800)
        .windowStyle(.hiddenTitleBar)
        // Hide non-transient system overlays so the macOS 26 menu-bar area
        // reservation doesn't render a lighter stripe across the top of the
        // window in fullscreen. The system menu bar still appears on hover.
        .persistentSystemOverlays(.hidden)
    }
}

/// AppKit bridge that forces the underlying `NSWindow.backgroundColor` to
/// match `Theme.backdrop`. Without this, any region of the window that
/// SwiftUI doesn't cover (e.g. the fullscreen-mode title bar / menu bar
/// reservation in macOS 26) shows the system's default window background,
/// which is close-to-but-not-exactly `Theme.panel` and reads as a stripe.
private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { configure(view.window) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        configure(nsView.window)
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }
        // Bridge directly from SwiftUI Color → NSColor so the color spaces
        // match exactly (calibratedRGB vs sRGB caused a faintly-lighter band
        // in earlier attempts).
        window.backgroundColor = NSColor(Theme.backdrop)
        window.isOpaque = true
        // Title-bar transparency + content extension.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.styleMask.insert(.fullSizeContentView)
        // Remove the separator line that macOS 11+ draws below the title bar
        // (macOS 26 renders it heavier; this is one candidate for the stripe).
        window.titlebarSeparatorStyle = .none
        // Drop the AppKit toolbar so the window doesn't reserve toolbar space —
        // that reservation is what renders the lighter "Liquid Glass" stripe
        // across the top in fullscreen on macOS 26. This unavoidably also removes
        // NavigationSplitView's native sidebar toggle (it lives in the toolbar),
        // so the sidebar toggle is provided as an in-scene control in TopBar.
        window.toolbar = nil
    }
}
