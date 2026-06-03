import Foundation
import SwiftUI
import AppKit
import Quartz

@MainActor
final class BrowserViewModel: ObservableObject {

    /// Tree shown in the sidebar — anchored to the originally-picked folder, scanned deeply.
    @Published var sidebarRoot: FileSystemNode?

    /// Tree shown in the 3D scene — follows descent, scanned shallowly for snappy reloads.
    @Published var currentRoot: FileSystemNode?

    /// The item the user explicitly clicked/selected (drives the HUD and the file tilt).
    @Published var selectedURL: URL?
    /// The item currently under the cursor in the 3D view (HUD falls back to this).
    @Published var hoveredURL: URL?
    /// True while a directory scan is in flight (drives the toolbar spinner).
    @Published var isScanning: Bool = false
    /// Last scan error message, if any.
    @Published var lastError: String?

    /// A request for the 3D scene to fly its camera to a specific URL's node.
    /// The token disambiguates repeated requests for the same URL.
    struct FocusRequest: Equatable {
        let url: URL
        let token: Int
    }
    @Published private(set) var sceneFocusRequest: FocusRequest?
    private var focusCounter = 0

    /// Incremented to ask the 3D scene to re-frame the whole current folder.
    @Published private(set) var resetViewToken: Int = 0
    func requestResetView() { resetViewToken += 1 }

    /// Active strategy for coloring file slabs in the 3D scene. Changing this
    /// bumps `colorRebuildToken` so the scene rebuilds with the new palette.
    @Published var colorMode: ColorMode = .age {
        didSet {
            guard oldValue != colorMode else { return }
            colorRebuildToken += 1
        }
    }
    /// Incremented when `colorMode` changes; the scene coordinator watches this
    /// to know it must rebuild the level stack with new materials.
    @Published private(set) var colorRebuildToken: Int = 0

    private var history: [URL] = []

    private let sidebarMaxDepth = 3
    private let sceneMaxDepth = 3

    var currentURL: URL? { currentRoot?.url }
    var canGoBack: Bool { history.count > 1 }

    // MARK: - Folder picking

    /// Present an open panel for the user to pick a folder, then load it as a fresh
    /// root (resetting history and the 3D level stack).
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Visualize"
        panel.message = "Choose a folder to visualize"
        if panel.runModal() == .OK, let url = panel.url {
            Task { await loadInitial(url: url) }
        }
    }

    /// Make `url` the current 3D root (re-roots / pushes a layer). Pushed onto history.
    func descend(into url: URL) {
        Task { await loadCurrent(url: url) }
    }

    /// Navigate to an arbitrary folder (e.g. a breadcrumb segment). Same as descend;
    /// the 3D scene interprets the transition (pop to it if it's an ancestor already
    /// in the stack, otherwise re-layer).
    func navigate(to url: URL) {
        Task { await loadCurrent(url: url) }
    }

    /// The originally-opened folder — navigation is clamped at or below this, since
    /// the sandbox only granted access to it.
    var openedRootURL: URL? { sidebarRoot?.url }

    /// Step back to the previously-visited folder in history.
    func goBack() {
        guard history.count > 1 else { return }
        history.removeLast()
        let prev = history.removeLast()
        Task { await loadCurrent(url: prev) }
    }

    /// Re-scan and reload the current folder in place.
    func reload() {
        guard let url = currentURL else { return }
        Task { await loadCurrent(url: url) }
    }

    // MARK: - Loading

    /// Load a freshly-opened folder: scan it both deeply (for the sidebar tree) and
    /// shallowly (for the 3D scene), and reset history to this root.
    private func loadInitial(url: URL) async {
        isScanning = true
        lastError = nil
        defer { isScanning = false }
        do {
            async let sidebarTask = FileSystemScanner.scan(root: url, maxDepth: sidebarMaxDepth)
            async let sceneTask = FileSystemScanner.scan(root: url, maxDepth: sceneMaxDepth)
            let (sidebar, scene) = try await (sidebarTask, sceneTask)
            sidebarRoot = sidebar
            currentRoot = scene
            history = [url]
            selectedURL = nil
            hoveredURL = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Scan `url` shallowly and make it the current 3D root, appending to history.
    private func loadCurrent(url: URL) async {
        isScanning = true
        lastError = nil
        defer { isScanning = false }
        do {
            let node = try await FileSystemScanner.scan(root: url, maxDepth: sceneMaxDepth)
            currentRoot = node
            selectedURL = nil
            hoveredURL = nil
            history.append(url)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Sidebar interaction

    func sidebarActivate(_ node: FileSystemNode) {
        // Both files and folders focus in-place in the 3D view, keeping the root
        // folder visible. The scene falls back to re-rooting only if the target
        // isn't part of the currently-rendered visualization. (Right-click →
        // "Visualize" still re-roots explicitly.)
        select(node.url)
        requestSceneFocus(node.url)
    }

    /// Ask the 3D scene to fly its camera to `url` (no-op there if the node isn't
    /// in the current scene).
    func requestSceneFocus(_ url: URL) {
        focusCounter += 1
        sceneFocusRequest = FocusRequest(url: url, token: focusCounter)
    }

    /// Locate a node in the sidebar tree by URL (used to scroll the sidebar to a
    /// selection made in the 3D view).
    func sidebarNode(for url: URL) -> FileSystemNode? {
        guard let root = sidebarRoot else { return nil }
        return Self.findNode(in: root, path: url.path)
    }

    /// Depth-first search for the node whose URL path matches `path`.
    private static func findNode(in node: FileSystemNode, path: String) -> FileSystemNode? {
        if node.url.path == path { return node }
        for child in node.children {
            if let found = findNode(in: child, path: path) { return found }
        }
        return nil
    }

    // MARK: - Selection

    /// Set the explicitly-selected item (nil clears selection).
    func select(_ url: URL?) { selectedURL = url }
    /// Set the hovered item (nil clears hover).
    func hover(_ url: URL?) { hoveredURL = url }

    /// The item actions apply to: the selection if any, otherwise whatever is hovered.
    var actionableURL: URL? { selectedURL ?? hoveredURL }

    /// Open the actionable item in its default application.
    func openInDefaultApp() {
        guard let url = actionableURL else { return }
        NSWorkspace.shared.open(url)
    }

    /// Reveal the actionable item in Finder.
    func revealInFinder() {
        guard let url = actionableURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Copy the actionable item's full path to the system pasteboard.
    func copyPath() {
        guard let url = actionableURL else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(url.path, forType: .string)
    }

    /// Show (or update) the Quick Look panel for the actionable item.
    func quickLook() {
        guard let url = actionableURL else { return }
        QuickLookPreview.shared.preview(url: url)
    }
}
