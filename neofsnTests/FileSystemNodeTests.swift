import Testing
import Foundation
@testable import neofsn

struct FileSystemNodeTests {
    private func file(_ name: String, size: Int64) -> FileSystemNode {
        FileSystemNode(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                       isDirectory: false, size: size, modificationDate: nil)
    }
    private func dir(_ name: String, _ children: [FileSystemNode]) -> FileSystemNode {
        FileSystemNode(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                       isDirectory: true, size: 0, modificationDate: nil, children: children)
    }

    @Test func partitionsSubdirectoriesAndFiles() {
        let f = file("a.txt", size: 1)
        let sub = dir("sub", [])
        let root = dir("root", [sub, f])
        #expect(root.subdirectories == [sub])
        #expect(root.files == [f])
    }

    @Test func outlineChildrenIsNilForFile() {
        #expect(file("a.txt", size: 1).outlineChildren == nil)
    }

    @Test func outlineChildrenIsEmptyArrayForEmptyDirectory() {
        #expect(dir("empty", []).outlineChildren == [])
    }

    @Test func outlineChildrenReturnsChildrenForPopulatedDirectory() {
        let f = file("a.txt", size: 1)
        #expect(dir("d", [f]).outlineChildren == [f])
    }

    @Test func identityEqualityAndHashing() {
        let a = file("a.txt", size: 1)
        let b = file("a.txt", size: 1)   // same data, distinct UUID
        #expect(a == a)
        #expect(a != b)
        #expect(a.hashValue == a.hashValue)
    }
}
