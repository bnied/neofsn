import Testing
@testable import neofsn

struct FileKindTests {
    @Test func directoriesClassifyAsFolder() {
        #expect(FileKind.classify(name: "anything.txt", isDirectory: true) == .folder)
    }

    @Test(arguments: [
        ("main.swift", FileKind.code),
        ("photo.png", FileKind.image),
        ("song.mp3", FileKind.audio),
        ("clip.mov", FileKind.video),
        ("notes.md", FileKind.document),
        ("bundle.zip", FileKind.archive),
        ("config.json", FileKind.config),
        ("index.html", FileKind.web),
        ("run.sh", FileKind.executable),
        ("disk.dmg", FileKind.disk),
    ])
    func classifiesByExtension(name: String, expected: FileKind) {
        #expect(FileKind.classify(name: name, isDirectory: false) == expected)
    }

    @Test(arguments: [".env", ".eslintrc.json", ".env.local", ".gitignore"])
    func dotfilesAreHidden(name: String) {
        #expect(FileKind.classify(name: name, isDirectory: false) == .hidden)
    }

    @Test func noExtensionIsOther() {
        #expect(FileKind.classify(name: "Makefile", isDirectory: false) == .other)
    }

    @Test func unknownExtensionIsOther() {
        #expect(FileKind.classify(name: "data.xyz", isDirectory: false) == .other)
    }

    @Test func classificationIsCaseInsensitive() {
        #expect(FileKind.classify(name: "README.MD", isDirectory: false) == .document)
        #expect(FileKind.classify(name: "PHOTO.PNG", isDirectory: false) == .image)
    }
}
