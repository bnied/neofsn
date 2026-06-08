import Foundation

/// An isolated temporary directory for a single test, removed on deinit so
/// filesystem tests never touch user data and don't leak fixtures.
final class TempDir {
    let url: URL

    init() throws {
        url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("neofsn-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    /// Create a subdirectory (with intermediates) relative to the temp root.
    @discardableResult
    func makeDir(_ relativePath: String) throws -> URL {
        let dir = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Create a file of `bytes` zero bytes (with intermediate dirs) relative to the temp root.
    @discardableResult
    func makeFile(_ relativePath: String, bytes: Int = 0) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: file)
        return file
    }
}
