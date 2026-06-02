import SwiftUI

/// Finder-style hierarchical tree of the opened folder, shown in the split-view
/// sidebar. Clicking a row focuses it in the 3D view; selection scrolls into view.
struct SidebarView: View {

    @ObservedObject var viewModel: BrowserViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.hairline)
            content
        }
        // Extend the panel under the top safe area so the title-bar strip is filled
        // (the header already pads down to clear the traffic lights).
        .background(Theme.panel.ignoresSafeArea(edges: .top))
    }

    private var header: some View {
        HStack {
            Text("filesystem")
                .capsLabel(color: Theme.textSecondary)
                .tracking(3)
            Spacer()
            if let root = viewModel.sidebarRoot {
                Text("\(root.children.count)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 36)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let root = viewModel.sidebarRoot {
            ScrollViewReader { proxy in
                List {
                    OutlineGroup(root, children: \.outlineChildren) { node in
                        NodeRow(node: node, viewModel: viewModel)
                            .id(node.id)
                            .listRowInsets(EdgeInsets(top: 1, leading: 4, bottom: 1, trailing: 4))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                .background(Theme.panel)
                .onChange(of: viewModel.selectedURL) { _, newURL in
                    // When something is selected (here or in the 3D view), reveal it
                    // in the sidebar by scrolling to its row if that row is rendered.
                    guard let url = newURL, let node = viewModel.sidebarNode(for: url) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) {
                        proxy.scrollTo(node.id, anchor: .center)
                    }
                }
            }
        } else {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "tray")
                    .font(.system(size: 22, weight: .ultraLight))
                    .foregroundStyle(Theme.textTertiary)
                Text("no folder open")
                    .capsLabel(color: Theme.textTertiary)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct NodeRow: View {

    let node: FileSystemNode
    @ObservedObject var viewModel: BrowserViewModel

    private var isCurrent: Bool { viewModel.currentURL == node.url }
    private var isSelected: Bool { viewModel.selectedURL == node.url }

    var body: some View {
        HStack(spacing: 8) {
            // Accent rail (only when current)
            Rectangle()
                .fill(isCurrent ? Theme.accent : Color.clear)
                .frame(width: 2)

            Image(systemName: icon)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(iconTint)
                .frame(width: 14, alignment: .center)

            Text(node.name)
                .font(Theme.body(12, weight: isCurrent ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundStyle(textColor)

            Spacer(minLength: 6)

            if isCurrent {
                Text("here")
                    .font(Theme.caps(8))
                    .tracking(1.6)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.accent.opacity(0.85))
                    .padding(.trailing, 4)
            }
        }
        .padding(.vertical, 3)
        .padding(.trailing, 4)
        .contentShape(Rectangle())
        .background(rowBackground)
        .onTapGesture(count: 2) {
            if !node.isDirectory {
                NSWorkspace.shared.open(node.url)
            } else {
                viewModel.descend(into: node.url)
            }
        }
        .onTapGesture(count: 1) {
            viewModel.sidebarActivate(node)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([node.url])
            }
            if !node.isDirectory {
                Button("Open") { NSWorkspace.shared.open(node.url) }
            }
            if node.isDirectory {
                Button("Visualize") { viewModel.descend(into: node.url) }
            }
        }
    }

    private var icon: String {
        node.isDirectory ? "folder" : "doc"
    }

    private var iconTint: Color {
        if isCurrent { return Theme.accent }
        return node.isDirectory ? Theme.accent.opacity(0.7) : Theme.textTertiary
    }

    private var textColor: Color {
        if isCurrent { return Theme.textPrimary }
        if isSelected { return Theme.textPrimary }
        return Theme.textSecondary
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isCurrent {
            Theme.accentWash
        } else if isSelected {
            Theme.panelRaised
        } else {
            Color.clear
        }
    }
}
