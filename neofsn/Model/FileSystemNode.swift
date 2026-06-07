import Foundation

/// One entry in the scanned filesystem tree (a file or a directory). Reference type
/// so SceneKit nodes and SwiftUI rows can share identity by `id`.
///
/// `@unchecked Sendable`: every stored property is immutable after `init` (the
/// scanner builds the whole tree, then only reads it), so the tree can safely be
/// handed to a background task that builds the 3D level off the main thread.
final class FileSystemNode: Identifiable, Hashable, @unchecked Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    var children: [FileSystemNode]
    /// False if this directory existed but its contents couldn't be read (e.g.
    /// permission denied), so the UI can distinguish "empty" from "unreadable".
    let isReadable: Bool

    /// Create a node from already-scanned attributes.
    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modificationDate: Date?,
        children: [FileSystemNode] = [],
        isReadable: Bool = true
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.children = children
        self.isReadable = isReadable
    }

    /// Identity equality (each scanned node has a unique `id`).
    static func == (lhs: FileSystemNode, rhs: FileSystemNode) -> Bool {
        lhs.id == rhs.id
    }

    /// Hash by identity, matching `==`.
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    /// Child directories only.
    var subdirectories: [FileSystemNode] { children.filter(\.isDirectory) }
    /// Child files only.
    var files: [FileSystemNode] { children.filter { !$0.isDirectory } }

    /// OutlineGroup contract: nil = leaf (no chevron); empty array = expandable but currently empty.
    var outlineChildren: [FileSystemNode]? {
        isDirectory ? children : nil
    }

    /// Total size of this node: a file's own size, or the recursive sum for a directory.
    var aggregateSize: Int64 {
        isDirectory ? children.reduce(0) { $0 + $1.aggregateSize } : size
    }
}
