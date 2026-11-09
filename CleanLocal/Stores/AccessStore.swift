import AppKit
import Foundation
import Observation

/// Persisted security-scoped bookmarks for cleanup features.
struct AccessGrants: Codable, Sendable {
    var home: Data?
    var trash: Data?
    var developerFolders: [ScanLocation] = []
}

/// The folders CleanLocal may clean, granted by the user in standard macOS open panels.
///
/// The App Sandbox blocks everything in your home folder by default. Cleanup features need
/// the **Home folder** (caches, logs, developer caches, Downloads) and, separately, the
/// **Trash**, which macOS protects with an extra privacy rule.
@MainActor
@Observable
final class AccessStore {
    private(set) var homeURL: URL?
    private(set) var trashURL: URL?
    private(set) var developerFolders: [ScanLocation] = []
    private(set) var audit: [AccessCheck] = []
    var presentedError: PresentableError?

    @ObservationIgnored private let persistence: PersistenceController
    @ObservationIgnored private let bookmarks: BookmarkManager
    @ObservationIgnored private var grants: [String: SecurityScopedAccess] = [:]
    @ObservationIgnored private var stored = AccessGrants()

    init(persistence: PersistenceController, bookmarks: BookmarkManager = BookmarkManager()) {
        self.persistence = persistence
        self.bookmarks = bookmarks
    }

    var hasHomeAccess: Bool { homeURL != nil }
    var hasTrashAccess: Bool { trashURL != nil }

    var homeLayout: HomeLayout? {
        guard let homeURL else { return nil }
        return HomeLayout(home: homeURL, projectRoots: developerFolders.map { URL(fileURLWithPath: $0.path) })
    }

    // MARK: Lifecycle

    func bootstrap() async {
        stored = await persistence.accessGrants.load()
        homeURL = activate(key: "home", bookmark: stored.home)
        trashURL = activate(key: "trash", bookmark: stored.trash)
        developerFolders = stored.developerFolders.filter { location in
            activate(key: location.id.uuidString, bookmark: location.bookmarkData) != nil || isInsideHome(location.path)
        }
    }

    func shutdown() {
        grants.values.forEach { $0.stop() }
        grants.removeAll()
    }

    /// Re-checks access off the main thread (filesystem probes can block).
    func refreshAudit() {
        Task {
            audit = await Task.detached(priority: .utility) { AccessAuditor.audit() }.value
        }
    }

    private func activate(key: String, bookmark: Data?) -> URL? {
        guard let bookmark, let resolution = try? bookmarks.resolve(bookmark) else { return nil }
        let access = SecurityScopedAccess(url: resolution.url)
        guard FileManager.default.isReadableFile(atPath: resolution.url.path) else {
            access.stop()
            return nil
        }
        grants[key]?.stop()
        grants[key] = access
        return resolution.url
    }

    private func isInsideHome(_ path: String) -> Bool {
        guard let homeURL else { return false }
        return path.hasPrefix(homeURL.path + "/")
    }

    // MARK: Granting

    /// Asks the user to grant their Home folder (one open panel, pre-navigated).
    func grantHomeAccess() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = UserDirectories.realHomeURL.deletingLastPathComponent()
        panel.prompt = "Grant Access"
        panel.message = "Select your Home folder (“\(UserDirectories.realHomeURL.lastPathComponent)”) so CleanLocal can find caches, logs and developer files. Nothing leaves your Mac and nothing is removed without your confirmation."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL.path == UserDirectories.realHomePath else {
            presentedError = PresentableError(title: "Please Choose Your Home Folder",
                                              message: "Cleanup needs your Home folder (\(UserDirectories.realHomePath)), not \(url.path).")
            return
        }
        store(url, key: "home") { $0.home = $1 }
        homeURL = activate(key: "home", bookmark: stored.home)
        refreshAudit()
    }

    /// Asks the user to grant the Trash folder (hidden, so the panel shows hidden files).
    func grantTrashAccess() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = false
        panel.directoryURL = UserDirectories.realHomeURL
        panel.prompt = "Grant Access"
        panel.message = "Select the “.Trash” folder in your Home folder so CleanLocal can show what’s in the Trash and empty it when you ask."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.standardizedFileURL.path == UserDirectories.realHomePath + "/.Trash" else {
            presentedError = PresentableError(title: "Please Choose the Trash Folder",
                                              message: "Select the hidden “.Trash” folder inside your Home folder.")
            return
        }
        store(url, key: "trash") { $0.trash = $1 }
        trashURL = activate(key: "trash", bookmark: stored.trash)
        refreshAudit()
    }

    /// Developer project folders searched for node_modules, build outputs and virtual envs.
    func addDeveloperFolders() {
        for url in LocationPicker.chooseFolders() {
            guard !developerFolders.contains(where: { $0.path == url.path }) else { continue }
            guard let bookmark = try? bookmarks.makeBookmark(for: url) else { continue }
            let location = ScanLocation(displayName: url.lastPathComponent, path: url.path, bookmarkData: bookmark)
            _ = activate(key: location.id.uuidString, bookmark: bookmark)
            developerFolders.append(location)
        }
        persist { $0.developerFolders = self.developerFolders }
    }

    func removeDeveloperFolder(_ id: UUID) {
        grants.removeValue(forKey: id.uuidString)?.stop()
        developerFolders.removeAll { $0.id == id }
        persist { $0.developerFolders = self.developerFolders }
    }

    func revoke(home: Bool) {
        let key = home ? "home" : "trash"
        grants.removeValue(forKey: key)?.stop()
        if home { homeURL = nil } else { trashURL = nil }
        persist { grants in if home { grants.home = nil } else { grants.trash = nil } }
        refreshAudit()
    }

    private func store(_ url: URL, key: String, assign: (inout AccessGrants, Data) -> Void) {
        do {
            let bookmark = try bookmarks.makeBookmark(for: url)
            persist { assign(&$0, bookmark) }
        } catch {
            presentedError = PresentableError(title: "Couldn’t Save Access", error: error)
        }
    }

    private func persist(_ change: (inout AccessGrants) -> Void) {
        change(&stored)
        let snapshot = stored
        Task { try? await persistence.accessGrants.save(snapshot) }
    }

    // MARK: Testing support

    /// Sets folders directly (unit tests use temporary directories).
    func useForTesting(home: URL?, trash: URL?, developerFolders: [URL] = []) {
        homeURL = home
        trashURL = trash
        self.developerFolders = developerFolders.map { ScanLocation(displayName: $0.lastPathComponent, path: $0.path, bookmarkData: Data()) }
    }
}
