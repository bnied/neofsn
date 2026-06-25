import SwiftUI
import AppKit

/// Bottom instrument panel showing the actionable item's kind, name, path, size,
/// timestamps, age, permissions, and a row of inline actions. Hidden when nothing
/// is selected or hovered.
struct MetadataHUD: View {

    var viewModel: BrowserViewModel

    /// Last loaded metadata, kept alongside the URL it describes. Loading runs in
    /// `.task(id:)` below — never in `body` — because reading attributes (and a
    /// directory's full child list) is disk I/O that would otherwise re-run
    /// synchronously on the main thread every render, once per hovered item.
    @State private var loaded: (url: URL, info: Info)?

    var body: some View {
        Group {
            if let loaded {
                panel(info: loaded.info, url: loaded.url)
            }
        }
        .task(id: viewModel.actionableURL) {
            guard let url = viewModel.actionableURL else {
                loaded = nil
                return
            }
            // Off the main thread; while it loads, the previous item's panel
            // stays up so rapid hovering doesn't flicker the HUD.
            let info = await Task.detached(priority: .userInitiated) { Self.readInfo(for: url) }.value
            guard !Task.isCancelled else { return }   // a newer URL took over
            loaded = info.map { (url, $0) }
        }
    }

    @ViewBuilder
    private func panel(info: Info, url: URL) -> some View {
        HStack(alignment: .top, spacing: 0) {
                specimen(info: info, url: url)
                    .padding(.trailing, 14)

                vRule

                statBlock(label: info.sizeLabel, value: info.sizeText,
                          sub: info.sizeSub, width: 88)
                vRule
                statBlock(label: "MODIFIED", value: info.modifiedText,
                          sub: info.ageText, width: 102)
                vRule
                statBlock(label: "CREATED", value: info.createdText,
                          sub: nil, width: 88)
                vRule
                statBlock(label: "PERMS", value: info.permsText,
                          sub: nil, width: 46)

                vRule

                actionStrip(info: info)
                    .padding(.leading, 10)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .fixedSize(horizontal: false, vertical: true)
            .instrumentPanel()
    }

    @ViewBuilder
    private var vRule: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 0.5)
            .padding(.vertical, 4)
    }

    /// Left block: kind chip, italic-serif name, and full path.
    @ViewBuilder
    private func specimen(info: Info, url: URL) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: info.kind.iconName)
                    .font(.system(size: 9))
                    .foregroundStyle(info.isDirectory ? Theme.folder : Theme.textSecondary)
                Text(info.kindChipText.uppercased()).capsLabel(color: Theme.textTertiary)
            }
            Text(info.name)
                .font(Theme.display(15, weight: .regular))
                .italic()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(url.path)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.textTertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(width: 200, alignment: .leading)
    }

    /// A single fixed-width stat column (tracked caps label over a monospaced value,
    /// with an optional small secondary line beneath).
    @ViewBuilder
    private func statBlock(label: String, value: String, sub: String?, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).capsLabel()
            Text(value)
                .font(Theme.mono(11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if let sub {
                Text(sub)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 8)
    }

    // MARK: - Actions

    /// Inline vertical column of compact action buttons. Quick Look is first
    /// (most common) and folders get a Descend button to enter them in 3D.
    @ViewBuilder
    private func actionStrip(info: Info) -> some View {
        HStack(spacing: 6) {
            actionButton(systemName: "eye", help: "Quick Look (Space)") {
                viewModel.quickLook()
            }
            actionButton(systemName: "arrow.up.right.square", help: "Open (⇧⌘O)") {
                viewModel.openInDefaultApp()
            }
            actionButton(systemName: "doc.on.clipboard", help: "Copy Path (⇧⌘C)") {
                viewModel.copyPath()
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            actionButton(systemName: "magnifyingglass", help: "Reveal in Finder (⌘R)") {
                viewModel.revealInFinder()
            }
            if info.isDirectory, let url = viewModel.actionableURL {
                actionButton(systemName: "arrow.down.forward.square", help: "Descend") {
                    viewModel.descend(into: url)
                }
            }
        }
    }

    @ViewBuilder
    private func actionButton(systemName: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Info

    private struct Info {
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
        let created: Date?
        let fileCount: Int?
        let subdirCount: Int?
        let isReadable: Bool
        let isWritable: Bool
        let isExecutable: Bool
        let kind: FileKind

        var kindChipText: String { kind.label }

        var sizeLabel: String { isDirectory ? "ITEMS" : "SIZE" }

        var sizeText: String {
            if isDirectory {
                let total = (fileCount ?? 0) + (subdirCount ?? 0)
                return "\(total)"
            }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }

        /// For folders: "N files · M dirs". For files: nothing.
        var sizeSub: String? {
            guard isDirectory else { return nil }
            let f = fileCount ?? 0
            let d = subdirCount ?? 0
            return "\(f) file\(f == 1 ? "" : "s") · \(d) dir\(d == 1 ? "" : "s")"
        }

        var modifiedText: String { format(modified) }
        var createdText: String { format(created) }

        var ageText: String {
            guard let modified else { return "—" }
            let days = Int(Date().timeIntervalSince(modified) / 86_400)
            switch days {
            case ..<1:   return "today"
            case ..<2:   return "1 d ago"
            case ..<7:   return "\(days) d ago"
            case ..<31:  return "\(days / 7) wk ago"
            case ..<365: return "\(days / 30) mo ago"
            default:     return "\(days / 365) yr ago"
            }
        }

        var permsText: String {
            let r = isReadable ? "r" : "-"
            let w = isWritable ? "w" : "-"
            let x = isExecutable ? "x" : "-"
            return r + w + x
        }

        /// Shared formatter — building a DateFormatter is expensive, and `format`
        /// runs in the render path.
        private static let dateFormatter: DateFormatter = {
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy"
            return f
        }()

        private func format(_ date: Date?) -> String {
            guard let date else { return "—" }
            return Self.dateFormatter.string(from: date)
        }
    }

    /// Read the displayed attributes for `url` from disk, or nil if it can't be
    /// read. `nonisolated` on purpose: it's blocking I/O, called from a detached
    /// task — never from the main actor.
    private nonisolated static func readInfo(for url: URL) -> Info? {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .creationDateKey, .nameKey,
        ]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isDir = v.isDirectory ?? false
        let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        let name = v.name ?? url.lastPathComponent

        var fileCount: Int?
        var subdirCount: Int?
        if isDir,
           let entries = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
           ) {
            var files = 0
            var dirs = 0
            for entry in entries {
                let isSubDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if isSubDir { dirs += 1 } else { files += 1 }
            }
            fileCount = files
            subdirCount = dirs
        }

        let fm = FileManager.default
        let path = url.path
        return Info(
            name: name,
            isDirectory: isDir,
            size: size,
            modified: v.contentModificationDate,
            created: v.creationDate,
            fileCount: fileCount,
            subdirCount: subdirCount,
            isReadable: fm.isReadableFile(atPath: path),
            isWritable: fm.isWritableFile(atPath: path),
            isExecutable: fm.isExecutableFile(atPath: path),
            kind: FileKind.classify(name: name, isDirectory: isDir)
        )
    }
}
