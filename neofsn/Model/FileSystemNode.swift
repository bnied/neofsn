import Foundation

/// One entry in the scanned filesystem tree (a file or a directory). Reference type
/// so SceneKit nodes and SwiftUI rows can share identity by `id`.
final class FileSystemNode: Identifiable, Hashable {
    let id = UUID()
    let url: URL
    let name: String
    let isDirectory: Bool
    let size: Int64
    let modificationDate: Date?
    var children: [FileSystemNode]

    /// Create a node from already-scanned attributes.
    init(
        url: URL,
        name: String,
        isDirectory: Bool,
        size: Int64,
        modificationDate: Date?,
        children: [FileSystemNode] = []
    ) {
        self.url = url
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
        self.children = children
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
