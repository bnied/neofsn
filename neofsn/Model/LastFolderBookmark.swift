import Foundation

/// Persists a security-scoped bookmark for the last folder the user opened, so
/// the app can restore access to it on the next launch (the sandbox grant from
/// `NSOpenPanel` only lasts for the session; bookmarks make it durable — this is
/// what the `com.apple.security.files.bookmarks.app-scope` entitlement enables).
struct LastFolderBookmark {
    private static let key = "lastOpenedFolderBookmark"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Store a security-scoped bookmark for `url`. Failures (e.g. the URL isn't
    /// bookmarkable) just leave the previous value in place — restoring last
    /// session's folder is best-effort, never an error the user sees.
    func save(_ url: URL) {
        guard let data = try? url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) else { return }
        defaults.set(data, forKey: Self.key)
    }

    /// Resolve the saved bookmark and begin security-scoped access to it.
    /// Returns nil if nothing was saved, the target no longer exists, or the
    /// sandbox refuses access. Access is intentionally never stopped — the app
    /// reads the folder for its whole lifetime.
    func restore() -> URL? {
        guard let data = defaults.data(forKey: Self.key) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }
        guard url.startAccessingSecurityScopedResource() else { return nil }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }
        if isStale { save(url) }   // refresh so the bookmark survives moves/renames
        return url
    }
}
