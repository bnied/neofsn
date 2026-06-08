import Testing
import Foundation
@testable import neofsn

struct FileSystemScannerTests {
    @Test func scansDirectChildren() async throws {
        let tmp = try TempDir()
        try tmp.makeFile("b.txt", bytes: 3)
        try tmp.makeDir("sub")
        let node = try await FileSystemScanner.scan(root: tmp.url, maxDepth: 1)
        #expect(node.isDirectory)
        #expect(node.children.count == 2)
    }

    @Test func ordersDirectoriesBeforeFilesThenCaseInsensitiveName() async throws {
        let tmp = try TempDir()
        try tmp.makeFile("Zebra.txt")
        try tmp.makeFile("apple.txt")
        try tmp.makeDir("Mango")
        try tmp.makeDir("beta")
        let node = try await FileSystemScanner.scan(root: tmp.url, maxDepth: 1)
        // dirs first (case-insensitive: beta < Mango), then files (apple < Zebra)
        #expect(node.children.map(\.name) == ["beta", "Mango", "apple.txt", "Zebra.txt"])
    }

    @Test func maxDepthClampsRecursion() async throws {
        let tmp = try TempDir()
        try tmp.makeDir("sub/deep")
        let node = try await FileSystemScanner.scan(root: tmp.url, maxDepth: 1)
        let sub = try #require(node.children.first { $0.name == "sub" })
        #expect(sub.children.isEmpty)   // depth 1 → "sub" is not descended into
    }

    @Test func skipsHiddenFiles() async throws {
        let tmp = try TempDir()
        try tmp.makeFile(".secret")
        try tmp.makeFile("visible.txt")
        let node = try await FileSystemScanner.scan(root: tmp.url, maxDepth: 1)
        #expect(node.children.map(\.name) == ["visible.txt"])
    }

    @Test func unreadableDirectoryIsMarkedUnreadable() async throws {
        let tmp = try TempDir()
        let locked = try tmp.makeDir("locked")
        try tmp.makeFile("locked/inside.txt")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        // Running as root bypasses POSIX permission bits, so the dir stays readable.
        guard getuid() != 0 else { return }

        let node = try await FileSystemScanner.scan(root: tmp.url, maxDepth: 2)
        let lockedNode = try #require(node.children.first { $0.name == "locked" })
        #expect(lockedNode.isReadable == false)
    }
}
