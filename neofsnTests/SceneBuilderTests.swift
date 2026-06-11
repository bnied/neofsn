import Testing
import Foundation
import AppKit
@testable import neofsn

struct SceneBuilderTests {
    private func fileNode(_ name: String, size: Int64 = 10) -> FileSystemNode {
        FileSystemNode(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                       isDirectory: false, size: size, modificationDate: nil)
    }
    private func dirNode(_ name: String, _ children: [FileSystemNode]) -> FileSystemNode {
        FileSystemNode(url: URL(fileURLWithPath: "/tmp/\(name)"), name: name,
                       isDirectory: true, size: 0, modificationDate: nil, children: children)
    }

    // MARK: - Color mode is an explicit parameter (no shared global)

    @Test func makeLevelNodeAppliesRequestedColorMode() {
        let root = dirNode("root", [fileNode("main.swift")])
        let built = SceneBuilder.makeLevelNode(root: root, parentURL: nil, colorMode: .type)
        let slab = built.node.childNodes.first { $0.name == "file" }
        let color = slab?.geometry?.firstMaterial?.diffuse.contents as? NSColor
        #expect(color == FileKind.code.sceneColor)   // .type palette, not age heatmap
    }

    @Test func recolorFileSlabsSwitchesPalette() {
        let root = dirNode("root", [fileNode("main.swift")])
        let built = SceneBuilder.makeLevelNode(root: root, parentURL: nil, colorMode: .age)
        SceneBuilder.recolorFileSlabs(under: built.node, colorMode: .type)
        let slab = built.node.childNodes.first { $0.name == "file" }
        let color = slab?.geometry?.firstMaterial?.diffuse.contents as? NSColor
        #expect(color == FileKind.code.sceneColor)
    }

    // MARK: - Layout math

    @Test func subdirTileWidthGrowsWithCountAndClamps() {
        let empty = SceneBuilder.subdirTileWidth(itemCount: 0)
        let small = SceneBuilder.subdirTileWidth(itemCount: 10)
        let huge = SceneBuilder.subdirTileWidth(itemCount: 1_000_000)
        #expect(empty == SceneBuilder.fileBaseWidth)          // empty folder = file-sized
        #expect(small > empty)                                // fuller reads bigger
        #expect(huge == SceneBuilder.fileBaseWidth * 2.4)     // clamped at 2.4×
    }

    @Test func slabHeightClampsToBudget() {
        let tiny = SceneBuilder.slabHeight(forSize: 0, max: 0.18)
        // log10(2000)·0.05 ≈ 0.165 — inside the 0.07…0.18 budget, so unclamped.
        let mid = SceneBuilder.slabHeight(forSize: 2_000, max: 0.18)
        let huge = SceneBuilder.slabHeight(forSize: .max, max: 0.18)
        #expect(tiny == 0.07)            // floor
        #expect(mid > tiny && mid < 0.18)
        #expect(huge == 0.18)            // ceiling
    }

    @Test func truncateToAspectShortensLongNamesWithEllipsis() {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 72)]
        let long = String(repeating: "filename-", count: 20)
        let out = SceneBuilder.truncateToAspect(text: long, attrs: attrs, maxAspect: 5)
        #expect(out.hasSuffix("\u{2026}"))
        #expect(out.count < long.count)
        let size = (out as NSString).size(withAttributes: attrs)
        #expect(size.width / size.height <= 5)

        let short = "a.txt"
        #expect(SceneBuilder.truncateToAspect(text: short, attrs: attrs, maxAspect: 5) == short)
    }
}
