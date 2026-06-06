import Foundation

enum FileSystemScanner {

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .nameKey,
    ]

    /// Scan a directory shallowly: include immediate children, then recurse into
    /// directory children up to `maxDepth`. A `maxDepth` of 1 means only the
    /// top-level dir's direct children are populated.
    static func scan(root: URL, maxDepth: Int = 2) async throws -> FileSystemNode {
        try await Task.detached(priority: .userInitiated) {
            try scanSync(url: root, depth: 0, maxDepth: maxDepth)
        }.value
    }

    private static func scanSync(url: URL, depth: Int, maxDepth: Int) throws -> FileSystemNode {
        let values = try url.resourceValues(forKeys: Set(resourceKeys))
        let isDir = values.isDirectory ?? false
        let name = values.name ?? url.lastPathComponent
        let size = Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        let mtime = values.contentModificationDate

        guard isDir else {
            return FileSystemNode(
                url: url,
                name: name,
                isDirectory: false,
                size: size,
                modificationDate: mtime
            )
        }

        var children: [FileSystemNode] = []
        var isReadable = true
        if depth < maxDepth {
            let fm = FileManager.default
            do {
                let entries = try fm.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: resourceKeys,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
                for entry in entries {
                    if let child = try? scanSync(url: entry, depth: depth + 1, maxDepth: maxDepth) {
                        children.append(child)
                    }
                }
                children.sort { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            } catch {
                // Directory exists but its contents can't be listed (e.g. permission
                // denied) — surface that instead of rendering it as an empty folder.
                isReadable = false
            }
        }

        return FileSystemNode(
            url: url,
            name: name,
            isDirectory: true,
            size: 0,
            modificationDate: mtime,
            children: children,
            isReadable: isReadable
        )
    }
}
