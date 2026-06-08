import Testing
import Foundation
@testable import neofsn

@MainActor
struct BrowserViewModelTests {
    @Test func actionableURLPrefersSelectionOverHover() {
        let vm = BrowserViewModel()
        let hovered = URL(fileURLWithPath: "/tmp/hover")
        let selected = URL(fileURLWithPath: "/tmp/select")

        vm.hover(hovered)
        #expect(vm.actionableURL == hovered)        // falls back to hover

        vm.select(selected)
        #expect(vm.actionableURL == selected)        // selection wins

        vm.select(nil)
        #expect(vm.actionableURL == hovered)         // back to hover when selection cleared
    }

    @Test func canGoBackIsFalseInitially() {
        #expect(BrowserViewModel().canGoBack == false)
    }

    @Test func colorModeChangeBumpsRebuildToken() {
        let vm = BrowserViewModel()
        let before = vm.colorRebuildToken
        vm.colorMode = .type
        #expect(vm.colorRebuildToken == before + 1)   // change bumps token
        vm.colorMode = .type
        #expect(vm.colorRebuildToken == before + 1)   // no-op assignment does not
    }

    @Test func sidebarNodeFindsByURLAndMissesUnknown() {
        let vm = BrowserViewModel()
        let childURL = URL(fileURLWithPath: "/tmp/root/child")
        let child = FileSystemNode(url: childURL, name: "child",
                                   isDirectory: false, size: 1, modificationDate: nil)
        let root = FileSystemNode(url: URL(fileURLWithPath: "/tmp/root"), name: "root",
                                  isDirectory: true, size: 0, modificationDate: nil,
                                  children: [child])
        vm.sidebarRoot = root

        #expect(vm.sidebarNode(for: childURL) === child)                       // DFS hit
        #expect(vm.sidebarNode(for: root.url) === root)                        // root match
        #expect(vm.sidebarNode(for: URL(fileURLWithPath: "/nope")) == nil)     // miss
    }
}
