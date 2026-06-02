import SwiftUI

/// Bottom instrument panel showing the actionable item's kind, name, path, size,
/// modified date, and age. Hidden when nothing is selected or hovered.
struct MetadataHUD: View {

    @ObservedObject var viewModel: BrowserViewModel

    var body: some View {
        if let url = viewModel.actionableURL,
           let info = readInfo(for: url) {
            HStack(spacing: 0) {
                specimen(info: info, url: url)
                    .padding(.trailing, 14)

                vRule

                statBlock(label: "size", value: info.sizeText, width: 96)
                vRule
                statBlock(label: "modified", value: info.modifiedText, width: 118)
                vRule
                statBlock(label: "age", value: info.ageText, width: 70)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .fixedSize(horizontal: true, vertical: true)
            .instrumentPanel()
        }
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
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: info.isDirectory ? "folder.fill" : "doc.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(info.isDirectory ? Theme.accent : Theme.textSecondary)
                Text(info.kindLabel).capsLabel(color: Theme.textTertiary)
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
        .frame(width: 240, alignment: .leading)
    }

    /// A single fixed-width stat column (tracked caps label over a monospaced value).
    @ViewBuilder
    private func statBlock(label: String, value: String, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).capsLabel()
            Text(value)
                .font(Theme.mono(11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
        }
        .frame(width: width, alignment: .leading)
        .padding(.horizontal, 12)
    }

    // MARK: - Info

    private struct Info {
        let name: String
        let isDirectory: Bool
        let size: Int64
        let modified: Date?
        let itemCount: Int?

        var kindLabel: String {
            if isDirectory { return "folder" }
            let ext = (name as NSString).pathExtension.lowercased()
            return ext.isEmpty ? "file" : ext
        }
        var sizeText: String {
            if isDirectory, let count = itemCount { return "\(count) items" }
            return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        var modifiedText: String {
            guard let modified else { return "—" }
            let f = DateFormatter()
            f.dateFormat = "MMM d, yyyy"
            return f.string(from: modified)
        }
        var ageText: String {
            guard let modified else { return "—" }
            let days = Int(Date().timeIntervalSince(modified) / 86_400)
            switch days {
            case ..<1:   return "today"
            case ..<2:   return "1 d"
            case ..<7:   return "\(days) d"
            case ..<31:  return "\(days / 7) wk"
            case ..<365: return "\(days / 30) mo"
            default:     return "\(days / 365) yr"
            }
        }
    }

    /// Read the displayed attributes for `url` from disk, or nil if it can't be read.
    private func readInfo(for url: URL) -> Info? {
        let keys: [URLResourceKey] = [
            .isDirectoryKey, .fileSizeKey, .totalFileAllocatedSizeKey,
            .contentModificationDateKey, .nameKey,
        ]
        guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
        let isDir = v.isDirectory ?? false
        let size = Int64(v.totalFileAllocatedSize ?? v.fileSize ?? 0)
        let name = v.name ?? url.lastPathComponent
        var count: Int?
        if isDir {
            count = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.count
        }
        return Info(
            name: name,
            isDirectory: isDir,
            size: size,
            modified: v.contentModificationDate,
            itemCount: count
        )
    }
}
