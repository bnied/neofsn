import SwiftUI

struct ContentView: View {

    @State private var viewModel = BrowserViewModel()
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        ZStack {
            // Opaque base layer behind everything — paints corner-to-corner of
            // the window including any safe-area inset and any region that
            // SwiftUI's NavigationSplitView / toolbar chrome wouldn't normally
            // cover. If the fullscreen stripe is a gap where the backdrop never
            // reaches, this fills it. If the stripe survives even with this in
            // place, it's a layer being painted *on top* of content (Liquid
            // Glass material) and needs a different attack.
            Theme.backdrop.ignoresSafeArea(.all)

            NavigationSplitView(columnVisibility: $columnVisibility) {
                SidebarView(viewModel: viewModel)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 300, max: 480)
            } detail: {
                detailContent
            }
            .frame(minWidth: 1100, minHeight: 720)
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .toolbar(removing: .title)
        }
        .containerBackground(Theme.backdrop, for: .window)
        .preferredColorScheme(.dark)
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            previewSelected()
            return .handled
        }
        .task {
            // Reopen the previous session's folder (security-scoped bookmark).
            viewModel.restoreLastFolder()
        }
    }

    private var detailContent: some View {
        ZStack {
            // Paint the backdrop under the top safe area so the title-bar strip isn't
            // a bare-window stripe (this color matches the scene background).
            Theme.backdrop.ignoresSafeArea(edges: .top)

            if viewModel.currentRoot != nil {
                // Fill the detail column. We only ignore the TOP safe area (not leading),
                // so the scene background covers the title-bar strip without extending
                // across the sidebar divider (which would bias the camera centering).
                SceneHostView(viewModel: viewModel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .ignoresSafeArea(edges: .top)
                    .clipped()
            } else if !viewModel.isScanning {
                // Only when idle with no folder — during the first scan the loading
                // overlay takes over instead, so the two never blend together.
                // `.identity` removal (no cross-fade) means it's gone the instant
                // scanning starts, leaving only the overlay fading in over backdrop.
                EmptyStateView { viewModel.chooseFolder() }
                    .ignoresSafeArea(edges: .top)
                    .transition(.identity)
            }

            // Full-canvas loading overlay while a scan is in flight. Sits above the
            // scene but below the TopBar, so the breadcrumb stays put when navigating
            // into a slow folder; on first open (no TopBar yet) it covers the whole
            // detail area over the opaque base backdrop.
            if isLoading {
                LoadingOverlay(title: viewModel.scanningTitle)
                    .ignoresSafeArea(edges: .top)
                    .transition(.opacity)
            }

            VStack(spacing: 14) {
                if viewModel.currentRoot != nil {
                    TopBar(viewModel: viewModel, columnVisibility: $columnVisibility)
                }
                Spacer(minLength: 0)
                if viewModel.actionableURL != nil {
                    MetadataHUD(viewModel: viewModel)
                        .padding(.bottom, 20)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.easeInOut(duration: 0.25), value: isLoading)
    }

    /// Scan-in-flight or building the 3D scene — either way, show the loading overlay.
    private var isLoading: Bool { viewModel.isScanning || viewModel.isPreparingScene }

    /// Quick Look the actionable item (bound to the Space key).
    private func previewSelected() {
        viewModel.quickLook()
    }
}

// MARK: - Loading overlay

/// Full-canvas scanning indicator shown while a folder is being read. Echoes the
/// empty-state aesthetic (scope motif + serif wordmark) so the wait reads as part
/// of the app rather than a generic spinner.
private struct LoadingOverlay: View {
    let title: String?
    @State private var pulse = false

    var body: some View {
        ZStack {
            Theme.backdrop

            VStack(spacing: 22) {
                Image(systemName: "scope")
                    .font(.system(size: 38, weight: .ultraLight))
                    .foregroundStyle(Theme.accent)
                    .opacity(pulse ? 0.95 : 0.4)
                    .scaleEffect(pulse ? 1.05 : 0.95)

                VStack(spacing: 12) {
                    Text("SCANNING FILESYSTEM")
                        .capsLabel(color: Theme.textSecondary)
                        .tracking(3.5)

                    if let title, !title.isEmpty {
                        Text(title)
                            .font(Theme.display(30, weight: .ultraLight))
                            .italic()
                            .tracking(-0.5)
                            .foregroundStyle(Theme.textPrimary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: 420)
                    }
                }

                ScanBar()
                    .padding(.top, 6)
            }
            .padding(40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 0.85).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}

/// Indeterminate amber "scan" bar that sweeps left↔right on a faint track — a
/// theme-matched replacement for the system linear ProgressView (whose default
/// blue track clashed with the dark canvas).
private struct ScanBar: View {
    @State private var slide = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let seg = w * 0.4
            Capsule()
                .fill(Theme.accent)
                .frame(width: seg)
                .offset(x: slide ? w - seg : 0)
        }
        .frame(width: 200, height: 3)
        .background(Capsule().fill(Theme.hairline))
        .clipShape(Capsule())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                slide = true
            }
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let action: () -> Void

    var body: some View {
        ZStack {
            // Backdrop with a subtle radial gradient — gives the empty canvas atmosphere
            RadialGradient(
                colors: [
                    Color(red: 0.10, green: 0.10, blue: 0.13),
                    Theme.backdrop,
                ],
                center: .center,
                startRadius: 80,
                endRadius: 700
            )
            .ignoresSafeArea()

            // Faint grid overlay for "spatial" hint
            GeometryReader { proxy in
                Canvas { ctx, size in
                    ctx.opacity = 0.05
                    let spacing: CGFloat = 56
                    let strokeColor = GraphicsContext.Shading.color(Theme.textPrimary)
                    var x: CGFloat = 0
                    while x < size.width {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        ctx.stroke(path, with: strokeColor, lineWidth: 0.5)
                        x += spacing
                    }
                    var y: CGFloat = 0
                    while y < size.height {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(path, with: strokeColor, lineWidth: 0.5)
                        y += spacing
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
            .allowsHitTesting(false)

            VStack(spacing: 26) {
                Spacer()

                // Crosshair motif
                Image(systemName: "plus.viewfinder")
                    .font(.system(size: 36, weight: .ultraLight))
                    .foregroundStyle(Theme.accent.opacity(0.85))

                // Wordmark
                Text("neofsn")
                    .font(Theme.display(64, weight: .ultraLight))
                    .italic()
                    .tracking(-1)
                    .foregroundStyle(Theme.textPrimary)

                // Wordmark sub-rule
                HStack(spacing: 14) {
                    Rectangle().fill(Theme.hairlineStrong).frame(width: 48, height: 0.6)
                    Text("F · S · N — 0.1 — 2026")
                        .font(Theme.mono(10, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(Theme.textTertiary)
                    Rectangle().fill(Theme.hairlineStrong).frame(width: 48, height: 0.6)
                }

                // Tagline
                Text("A SPATIAL FILESYSTEM NAVIGATOR")
                    .capsLabel(color: Theme.textSecondary)
                    .tracking(3.5)

                Spacer().frame(height: 18)

                Button(action: action) {
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .font(.system(size: 13, weight: .regular))
                        Text("Open Folder…")
                            .font(Theme.body(13, weight: .medium))
                    }
                    .foregroundStyle(Theme.backdrop)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Theme.accent)
                    )
                }
                .buttonStyle(.plain)
                .keyboardShortcut("o", modifiers: .command)

                Spacer()
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Top bar

private struct TopBar: View {
    @Bindable var viewModel: BrowserViewModel
    @Binding var columnVisibility: NavigationSplitViewVisibility

    var body: some View {
        HStack(spacing: 10) {
            iconButton(systemName: "sidebar.leading", help: "Toggle Sidebar (⌃⌘S)") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
                }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])

            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 18)

            iconButton(systemName: "chevron.left", help: "Back (⌘[)") {
                viewModel.goBack()
            }
            .disabled(!viewModel.canGoBack)
            .keyboardShortcut("[", modifiers: .command)

            iconButton(systemName: "folder", label: "Open…", help: "Open Folder (⌘O)") {
                viewModel.chooseFolder()
            }
            .keyboardShortcut("o", modifiers: .command)

            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 18)

            if let url = viewModel.currentURL {
                PathBreadcrumbs(url: url, viewModel: viewModel)
            }

            Spacer(minLength: 12)

            if viewModel.isScanning {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("SCANNING")
                        .capsLabel()
                }
                .transition(.opacity)
            }

            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 18)

            ColorModeToggle(mode: $viewModel.colorMode)

            Rectangle().fill(Theme.hairline).frame(width: 0.5, height: 18)

            iconButton(systemName: "scope", help: "Reset View (⌘0)") {
                viewModel.requestResetView()
            }
            .keyboardShortcut("0", modifiers: .command)

            iconButton(systemName: "magnifyingglass", help: "Reveal in Finder (⌘R)") {
                viewModel.revealInFinder()
            }
            .disabled(viewModel.actionableURL == nil)
            .keyboardShortcut("r", modifiers: .command)

            iconButton(systemName: "arrow.up.right.square", help: "Open (⇧⌘O)") {
                viewModel.openInDefaultApp()
            }
            .disabled(viewModel.actionableURL == nil)
            .keyboardShortcut("o", modifiers: [.command, .shift])
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .instrumentPanel()
    }

    /// A compact bordered toolbar button: an SF Symbol with an optional text label.
    @ViewBuilder
    private func iconButton(systemName: String, label: String? = nil, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemName)
                    .font(.system(size: 12, weight: .regular))
                if let label {
                    Text(label).font(Theme.body(12, weight: .medium))
                }
            }
            .foregroundStyle(Theme.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Path breadcrumbs

private struct PathBreadcrumbs: View {
    let url: URL
    var viewModel: BrowserViewModel

    private struct Crumb: Identifiable {
        let id: Int
        let name: String
        let url: URL
        let navigable: Bool   // only at/below the opened root (sandbox boundary)
        let isLast: Bool
    }

    private var crumbs: [Crumb] {
        let comps = url.pathComponents.filter { $0 != "/" }
        let openedPath = viewModel.openedRootURL?.path
        var acc = URL(fileURLWithPath: "/")
        var result: [Crumb] = []
        for (i, comp) in comps.enumerated() {
            acc.appendPathComponent(comp)
            let navigable: Bool = {
                guard let openedPath else { return false }
                return acc.path == openedPath || acc.path.hasPrefix(openedPath + "/")
            }()
            result.append(Crumb(id: i, name: comp, url: acc,
                                navigable: navigable, isLast: i == comps.count - 1))
        }
        return result
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("/")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.textTertiary)
            ForEach(crumbs) { crumb in
                segment(crumb)
                if !crumb.isLast {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .light))
                        .foregroundStyle(Theme.textTertiary)
                }
            }
        }
        .lineLimit(1)
        .truncationMode(.head)
    }

    /// One breadcrumb segment: a navigable button when at/below the opened root and
    /// not the current folder, otherwise plain (dimmed) text.
    @ViewBuilder
    private func segment(_ crumb: Crumb) -> some View {
        let color = crumb.isLast ? Theme.accent
            : (crumb.navigable ? Theme.textSecondary : Theme.textTertiary)
        let label = Text(crumb.name)
            .font(Theme.mono(11, weight: crumb.isLast ? .semibold : .regular))
            .foregroundStyle(color)

        if crumb.navigable && !crumb.isLast {
            Button { viewModel.navigate(to: crumb.url) } label: { label }
                .buttonStyle(.plain)
                .help("Go to \(crumb.name)")
        } else {
            label
        }
    }
}

// MARK: - Color mode toggle

/// Two-segment switch in the top bar between age-heatmap and file-type coloring.
private struct ColorModeToggle: View {
    @Binding var mode: ColorMode

    var body: some View {
        HStack(spacing: 0) {
            segment(label: "AGE", value: .age, help: "Color by modification age")
            segment(label: "TYPE", value: .type, help: "Color by file type")
        }
        .overlay(
            RoundedRectangle(cornerRadius: 3)
                .stroke(Theme.hairline, lineWidth: 0.5)
        )
    }

    @ViewBuilder
    private func segment(label: String, value: ColorMode, help: String) -> some View {
        let selected = mode == value
        Button {
            mode = value
        } label: {
            Text(label)
                .font(Theme.caps(9))
                .tracking(2.0)
                .foregroundStyle(selected ? Theme.backdrop : Theme.textSecondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(selected ? Theme.accent : Color.clear)
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
