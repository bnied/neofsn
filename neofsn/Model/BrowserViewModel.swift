import Foundation
import SwiftUI
import AppKit

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
    /// True while a directory scan is in flight (drives the toolbar spinner and
    /// the full-canvas loading overlay).
    @Published var isScanning: Bool = false
    /// Name of the folder currently being scanned, shown on the loading overlay.
    @Published var scanningTitle: String?
    /// True while the 3D scene for the freshly-scanned folder is being built off
    /// the main thread. Keeps the loading overlay up through the build so the wait
    /// reads as one continuous "loading" instead of scan → freeze → pop-in. The
    /// scene coordinator clears it once the level is attached.
    @Published var isPreparingScene: Bool = false
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

    /// Incremented to ask the 3D scene to toggle the Quick Look panel. The scene
    /// coordinator owns the panel so it can drive it through the responder chain.
    @Published private(set) var quickLookToken: Int = 0

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

    /// Monotonic navigation counter. Each load captures the current value and, when
    /// its scan finishes, commits results (and clears the spinner) only if it is
    /// still the latest — so an earlier-but-slower scan can't clobber a newer
    /// navigation, and overlapping scans don't drop the spinner early.
    private var navGeneration = 0

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
        Task { await loadCurrent(url: url, history: .push) }
    }

    /// Navigate to an arbitrary folder (e.g. a breadcrumb segment or the back-up
    /// tile). If `url` is already in history (an ancestor we came through) the
    /// forward entries are truncated; otherwise it's appended — so Back keeps meaning
    /// "the previous folder" instead of growing the stack with duplicates.
    func navigate(to url: URL) {
        Task { await loadCurrent(url: url, history: .jump) }
    }

    /// The originally-opened folder — navigation is clamped at or below this, since
    /// the sandbox only granted access to it.
    var openedRootURL: URL? { sidebarRoot?.url }

    /// Step back to the previously-visited folder in history.
    func goBack() {
        guard history.count > 1 else { return }
        // Target the entry before the current one; `.jump` truncates history to it.
        let target = history[history.count - 2]
        Task { await loadCurrent(url: target, history: .jump) }
    }

    /// Re-scan and reload the current folder in place (history unchanged).
    func reload() {
        guard let url = currentURL else { return }
        Task { await loadCurrent(url: url, history: .keep) }
    }

    // MARK: - Loading

    /// How a successful load mutates the navigation history stack.
    private enum NavHistory {
        case push   // descend into a child → append
        case jump   // breadcrumb / back / arbitrary → truncate to it if present, else append
        case keep   // reload in place → leave history untouched
    }

    private func applyHistory(_ mode: NavHistory, url: URL) {
        switch mode {
        case .push:
            history.append(url)
        case .jump:
            if let idx = history.lastIndex(of: url) {
                history.removeSubrange((idx + 1)...)
            } else {
                history.append(url)
            }
        case .keep:
            break
        }
    }

    /// Load a freshly-opened folder and reset history to this root. The sidebar and
    /// scene currently use the same scan depth, so a single scan serves both.
    private func loadInitial(url: URL) async {
        navGeneration += 1
        let generation = navGeneration
        isScanning = true
        scanningTitle = url.lastPathComponent
        lastError = nil
        var didLoad = false
        do {
            let node = try await FileSystemScanner.scan(root: url, maxDepth: max(sidebarMaxDepth, sceneMaxDepth))
            guard generation == navGeneration else { return }   // superseded
            sidebarRoot = node
            currentRoot = node
            history = [url]
            selectedURL = nil
            hoveredURL = nil
            isPreparingScene = true   // hand off to the off-main scene build
            didLoad = true
        } catch {
            guard generation == navGeneration else { return }
            lastError = error.localizedDescription
        }
        // Drop the scan flag together with `isPreparingScene` so the overlay never
        // flickers off between the scan finishing and the build starting. On a
        // successful load the build phase (the scene coordinator) clears the title.
        if generation == navGeneration {
            isScanning = false
            if !didLoad { scanningTitle = nil }
        }
    }

    /// Scan `url` shallowly, make it the current 3D root, and update history per `mode`.
    /// A generation guard ensures a slower earlier scan can't overwrite a newer one.
    private func loadCurrent(url: URL, history mode: NavHistory) async {
        navGeneration += 1
        let generation = navGeneration
        isScanning = true
        scanningTitle = url.lastPathComponent
        lastError = nil
        var didLoad = false
        do {
            let node = try await FileSystemScanner.scan(root: url, maxDepth: sceneMaxDepth)
            guard generation == navGeneration else { return }   // superseded by a newer navigation
            currentRoot = node
            selectedURL = nil
            hoveredURL = nil
            applyHistory(mode, url: url)
            isPreparingScene = true   // hand off to the off-main scene build
            didLoad = true
        } catch {
            guard generation == navGeneration else { return }
            lastError = error.localizedDescription
        }
        if generation == navGeneration {
            isScanning = false
            if !didLoad { scanningTitle = nil }
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

    /// Toggle the Quick Look panel for the actionable item (handled by the scene
    /// coordinator via `quickLookToken`).
    func quickLook() {
        guard actionableURL != nil else { return }
        // Deferred to the next run-loop tick so the publish doesn't happen
        // inside a view update — `.onKeyPress(.space)` can dispatch its handler
        // synchronously during layout, which would otherwise trip SwiftUI's
        // "Publishing changes from within view updates" runtime warning.
        Task { @MainActor in quickLookToken += 1 }
    }
}
