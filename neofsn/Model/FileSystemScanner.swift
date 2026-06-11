import Foundation

enum FileSystemScanner {

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .isPackageKey,
        .fileSizeKey,
        .totalFileAllocatedSizeKey,
        .contentModificationDateKey,
        .nameKey,
    ]

    /// Scan a directory shallowly: include immediate children, then recurse into
    /// directory children up to `maxDepth`. A `maxDepth` of 1 means only the
    /// top-level dir's direct children are populated.
    ///
    /// Cooperatively cancellable: cancelling the awaiting task aborts the walk
    /// (throwing `CancellationError`), so a superseded navigation doesn't keep
    /// grinding through a large tree in the background.
    static func scan(root: URL, maxDepth: Int = 2) async throws -> FileSystemNode {
        let work = Task.detached(priority: .userInitiated) {
            try scanSync(url: root, depth: 0, maxDepth: maxDepth)
        }
        // Awaiting a detached task does NOT forward the awaiting task's
        // cancellation to it — bridge it explicitly.
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    private static func scanSync(url: URL, depth: Int, maxDepth: Int) throws -> FileSystemNode {
        try Task.checkCancellation()
        let values = try url.resourceValues(forKeys: Set(resourceKeys))
        // Packages (.app bundles, .photoslibrary, …) are directories on disk but
        // behave as opaque documents in Finder — treat them as leaf files here too.
        let isDir = (values.isDirectory ?? false) && !(values.isPackage ?? false)
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
                    options: [.skipsHiddenFiles]
                )
                for entry in entries {
                    // Check here, not just in scanSync: the `try?` below would
                    // otherwise swallow a child's CancellationError and keep walking.
                    try Task.checkCancellation()
                    if let child = try? scanSync(url: entry, depth: depth + 1, maxDepth: maxDepth) {
                        children.append(child)
                    }
                }
                children.sort { lhs, rhs in
                    if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory && !rhs.isDirectory }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
            } catch is CancellationError {
                throw CancellationError()
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
