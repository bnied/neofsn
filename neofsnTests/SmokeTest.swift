import Testing
@testable import neofsn

struct SmokeTest {
    @Test func testTargetIsWired() {
        // Confirms @testable import resolves and the Swift Testing runner executes.
        #expect(FileKind.folder.label == "folder")
    }
}
