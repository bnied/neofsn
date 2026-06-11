import Testing
import Foundation
@testable import neofsn

@MainActor
struct BrowserViewModelTests {
    /// A view model whose bookmark store writes to a throwaway defaults domain,
    /// so navigation tests don't pollute real preferences.
    private func makeVM() -> BrowserViewModel {
        BrowserViewModel(bookmark: LastFolderBookmark(
            defaults: UserDefaults(suiteName: "neofsn-tests-\(UUID().uuidString)")!))
    }

    // MARK: - Navigation history

    @Test func descendPushesHistoryAndGoBackReturns() async throws {
        let tmp = try TempDir()
        let sub = try tmp.makeDir("a")
        let vm = makeVM()

        await vm.loadFolder(tmp.url).value
        #expect(vm.currentURL == tmp.url)
        #expect(vm.canGoBack == false)

        await vm.descend(into: sub).value
        #expect(vm.currentURL == sub)
        #expect(vm.canGoBack)

        await vm.goBack().value
        #expect(vm.currentURL == tmp.url)
        #expect(vm.canGoBack == false)
    }

    @Test func navigateToAncestorTruncatesForwardHistory() async throws {
        let tmp = try TempDir()
        let a = try tmp.makeDir("a")
        let b = try tmp.makeDir("a/b")
        let vm = makeVM()

        await vm.loadFolder(tmp.url).value
        await vm.descend(into: a).value
        await vm.descend(into: b).value

        // Jump straight back to the root: forward entries (a, a/b) are dropped,
        // so Back has nowhere left to go.
        await vm.navigate(to: tmp.url).value
        #expect(vm.currentURL == tmp.url)
        #expect(vm.canGoBack == false)
    }

    @Test func reloadKeepsHistoryInPlace() async throws {
        let tmp = try TempDir()
        let a = try tmp.makeDir("a")
        let vm = makeVM()

        await vm.loadFolder(tmp.url).value
        await vm.descend(into: a).value
        await vm.reload().value
        #expect(vm.currentURL == a)
        #expect(vm.canGoBack)        // reload didn't grow or shrink history

        await vm.goBack().value
        #expect(vm.currentURL == tmp.url)
    }

    @Test func loadFolderResetsHistoryToNewRoot() async throws {
        let tmp = try TempDir()
        let a = try tmp.makeDir("a")
        let other = try tmp.makeDir("other")
        let vm = makeVM()

        await vm.loadFolder(tmp.url).value
        await vm.descend(into: a).value
        await vm.loadFolder(other).value
        #expect(vm.currentURL == other)
        #expect(vm.canGoBack == false)   // fresh root, fresh history
    }

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
