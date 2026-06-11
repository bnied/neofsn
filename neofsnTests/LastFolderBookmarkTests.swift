import Testing
import Foundation
@testable import neofsn

struct LastFolderBookmarkTests {
    /// A throwaway defaults domain so tests never touch real app preferences.
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "neofsn-tests-\(UUID().uuidString)")!
    }

    /// Compare paths with symlinks resolved (`/tmp` vs `/private/tmp`): bookmark
    /// resolution returns the canonical path, not the one used to create it.
    private func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    @Test func saveAndRestoreRoundTrips() throws {
        let tmp = try TempDir()
        let store = LastFolderBookmark(defaults: makeDefaults())
        store.save(tmp.url)
        let restored = try #require(store.restore())
        #expect(canonical(restored) == canonical(tmp.url))
    }

    @Test func restoreReturnsNilWhenNothingSaved() {
        #expect(LastFolderBookmark(defaults: makeDefaults()).restore() == nil)
    }

    @Test func restoreReturnsNilWhenTargetWasDeleted() throws {
        let defaults = makeDefaults()
        let store = LastFolderBookmark(defaults: defaults)
        let tmp = try TempDir()
        let doomed = try tmp.makeDir("doomed")
        store.save(doomed)
        try FileManager.default.removeItem(at: doomed)
        #expect(store.restore() == nil)
    }
}
