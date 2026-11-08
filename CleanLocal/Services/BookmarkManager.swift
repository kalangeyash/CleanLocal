import Foundation
import OSLog

/// Creates and resolves bookmarks that let CleanLocal re-open user-picked folders across
/// launches without asking again.
///
/// In the shipping (sandboxed) app bookmarks are security-scoped. The scope can be
/// disabled for unit tests, which run against temporary directories.
struct BookmarkManager: Sendable {
    struct Resolution: Sendable {
        let url: URL
        /// When `true` the bookmark still works but should be re-created and saved.
        let isStale: Bool
    }

    var usesSecurityScope: Bool = true

    func makeBookmark(for url: URL) throws -> Data {
        do {
            return try url.bookmarkData(
                options: usesSecurityScope ? [.withSecurityScope] : [],
                includingResourceValuesForKeys: [.volumeIsRemovableKey, .nameKey],
                relativeTo: nil
            )
        } catch {
            throw CleanLocalError.bookmarkCreationFailed(path: url.path, reason: error.localizedDescription)
        }
    }

    func resolve(_ data: Data) throws -> Resolution {
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: usesSecurityScope ? [.withSecurityScope, .withoutUI] : [.withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            return Resolution(url: url, isStale: isStale)
        } catch {
            throw CleanLocalError.bookmarkResolutionFailed(reason: error.localizedDescription)
        }
    }
}

/// An active grant of access to a security-scoped URL.
///
/// Access starts on creation and stops exactly once, on `stop()` or deinit, which keeps
/// `startAccessingSecurityScopedResource` / `stopAccessingSecurityScopedResource` balanced.
final class SecurityScopedAccess: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var isAccessing: Bool

    init(url: URL) {
        self.url = url
        // Returns false for URLs that are not security-scoped (e.g. in tests); access may
        // still be possible through other means, which callers verify separately.
        isAccessing = url.startAccessingSecurityScopedResource()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard isAccessing else { return }
        url.stopAccessingSecurityScopedResource()
        isAccessing = false
    }

    deinit { stop() }
}

/// Tracks access grants for every configured scan location.
@MainActor
final class LocationAccessManager {
    private let bookmarks: BookmarkManager
    private var grants: [UUID: SecurityScopedAccess] = [:]

    init(bookmarks: BookmarkManager) {
        self.bookmarks = bookmarks
    }

    struct Activation {
        let url: URL
        /// Fresh bookmark data when the stored bookmark was stale and was re-created.
        let refreshedBookmark: Data?
    }

    /// Resolves the location's bookmark, starts access and verifies the folder is readable.
    func activate(_ location: ScanLocation) throws -> Activation {
        if let existing = grants[location.id], isReadableDirectory(existing.url) {
            return Activation(url: existing.url, refreshedBookmark: nil)
        }
        deactivate(location.id)

        let resolution = try bookmarks.resolve(location.bookmarkData)
        let grant = SecurityScopedAccess(url: resolution.url)
        guard isReadableDirectory(resolution.url) else {
            grant.stop()
            throw CleanLocalError.accessDenied(path: resolution.url.path)
        }
        grants[location.id] = grant

        var refreshed: Data?
        if resolution.isStale {
            refreshed = try? bookmarks.makeBookmark(for: resolution.url)
            Logger.access.info("Refreshed stale bookmark for \(location.displayName, privacy: .public)")
        }
        return Activation(url: resolution.url, refreshedBookmark: refreshed)
    }

    func activeURL(for locationID: UUID) -> URL? {
        grants[locationID]?.url
    }

    func deactivate(_ locationID: UUID) {
        grants.removeValue(forKey: locationID)?.stop()
    }

    func deactivateAll() {
        grants.values.forEach { $0.stop() }
        grants.removeAll()
    }

    private func isReadableDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
            && FileManager.default.isReadableFile(atPath: url.path)
    }
}
