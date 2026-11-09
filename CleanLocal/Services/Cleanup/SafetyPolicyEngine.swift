import Foundation

/// The single authority on what CleanLocal may remove.
///
/// Every cleanup path — Smart Cleanup, the category modules, the Storage Analyzer, the
/// Trash Manager and media deletion — asks this engine before touching the filesystem,
/// and asks again immediately before the operation (the filesystem may have changed).
///
/// The engine is deliberately conservative: when it can't establish that something is
/// safe, the answer is `.review` or `.protected`. There is no override.
struct SafetyPolicyEngine: Sendable {
    /// The real user home (or a test home).
    let homePath: String
    /// Items modified this recently are considered in use.
    var activeWindow: TimeInterval = 15 * 60

    init(homePath: String = UserDirectories.realHomePath, activeWindow: TimeInterval = 15 * 60) {
        self.homePath = (homePath as NSString).standardizingPath
        self.activeWindow = activeWindow
    }

    // MARK: - Rules

    /// System locations that are never cleaned.
    static let systemPrefixes = [
        "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/opt", "/private",
        "/var", "/etc", "/tmp", "/cores", "/dev", "/Volumes/Recovery", "/.vol", "/Network",
    ]

    /// Home-relative locations holding credentials, personal data or app state.
    static let protectedHomeSubpaths = [
        "Library/Keychains", "Library/Cookies", "Library/Mail", "Library/Messages", "Library/Safari",
        "Library/Mobile Documents", "Library/CloudStorage", "Library/Accounts", "Library/Calendars",
        "Library/Contacts", "Library/IdentityServices", "Library/Sharing", "Library/Passes",
        "Library/Application Support/com.apple.TCC", "Library/Application Support/MobileSync",
        "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
        "Library/Developer/Xcode/UserData", "Library/MobileDevice", "Library/Developer/CoreSimulator/Devices",
        "Library/Containers/com.docker.docker", "Library/Group Containers/group.com.docker",
        "Library/Application Support/Google/Chrome", "Library/Application Support/Microsoft Edge",
        "Library/Application Support/BraveSoftware", "Library/Application Support/Firefox",
        "Library/Application Support/Arc", "Library/Photos", "Library/Biome", "Library/Daemon Containers",
        "Library/Preferences/com.apple.security", ".Trash", "Pictures/Photos Library.photoslibrary",
    ]

    /// Folder names that hold secrets wherever they appear.
    static let protectedComponents: Set<String> = [
        ".ssh", ".gnupg", ".aws", ".kube", ".azure", ".config/gcloud", ".password-store", "Keychains", ".git",
    ]

    /// Credential and signing material.
    static let credentialExtensions: Set<String> = [
        "keychain", "keychain-db", "kdbx", "p12", "pfx", "pem", "key", "cer", "mobileprovision", "provisionprofile",
    ]

    /// Application databases. Allowed only inside verified cache locations.
    static let databaseExtensions: Set<String> = [
        "sqlite", "sqlite3", "db", "sqlite-wal", "sqlite-shm", "realm", "sqlitedb", "store", "storedata",
    ]

    /// Bundle-like packages that must never be removed by cleanup (apps, libraries).
    static let protectedPackageExtensions: Set<String> = [
        "app", "appex", "framework", "kext", "systemextension", "photoslibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "fcpbundle", "logicx", "xcodeproj", "xcworkspace", "playground",
    ]

    // MARK: - Hard protection

    /// A reason `path` can never be removed by any cleanup flow, or `nil`.
    ///
    /// - Parameter allowDatabases: `true` only for verified cache roots, where `Cache.db`-style
    ///   files are rebuildable.
    func hardProtectionReason(for path: String, allowDatabases: Bool = false) -> String? {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/") else { return "Not an absolute path" }

        let underHome = standardized.hasPrefix(homePath + "/")
        let onExternalVolume = standardized.hasPrefix("/Volumes/") && !standardized.hasPrefix("/Volumes/Recovery")
        guard underHome || onExternalVolume else {
            return "Outside your home folder and external drives"
        }
        if !underHome {
            for prefix in Self.systemPrefixes where standardized == prefix || standardized.hasPrefix(prefix + "/") {
                return "System location"
            }
        }

        if underHome {
            let relative = String(standardized.dropFirst(homePath.count + 1))
            if !relative.contains("/") { return "Top-level folder in your home" }
            for protected in Self.protectedHomeSubpaths where relative == protected || relative.hasPrefix(protected + "/") {
                return "Protected location (~/\(protected))"
            }
        } else {
            let components = standardized.split(separator: "/")
            if components.count <= 2 { return "Volume root" }
        }

        let components = standardized.split(separator: "/").map(String.init)
        for component in components where Self.protectedComponents.contains(component) {
            return "Contains credentials or configuration (\(component))"
        }
        let fileExtension = (standardized as NSString).pathExtension.lowercased()
        if Self.credentialExtensions.contains(fileExtension) {
            return "Credential or signing file"
        }
        // "Foo.app" is a package; "com.example.app" is a bundle-identifier-named folder.
        let lastComponent = (standardized as NSString).lastPathComponent
        if Self.protectedPackageExtensions.contains(fileExtension), BundleIdentifier.extract(from: lastComponent) == nil {
            return "Application or library package"
        }
        if !allowDatabases, Self.databaseExtensions.contains(fileExtension) {
            return "Application database"
        }
        return nil
    }

    // MARK: - Classification

    struct Context: Sendable {
        var runningBundleIDs: Set<String>
        var now: Date = .now
    }

    /// Final classification for a scanned candidate.
    func classify(
        _ candidate: CleanupCandidate,
        category: CleanupCategory,
        info: FileSpaceInfo?,
        context: Context
    ) -> (SafetyLevel, [String]) {
        let reasons = candidate.reasons
        let allowDatabases = category.group == .applicationCache || category.group == .browser || category.group == .developer

        if let hard = hardProtectionReason(for: candidate.url.path, allowDatabases: allowDatabases) {
            return (.protected, reasons + [hard])
        }
        guard let info else { return (.protected, reasons + ["Couldn’t read this item"]) }
        if info.isSymbolicLink { return (.protected, reasons + ["Symbolic link — the link target is never touched"]) }
        if info.isImmutable { return (.protected, reasons + ["Locked in Finder"]) }

        if category.requiresOwnerClosed, let owner = candidate.owner, context.runningBundleIDs.contains(owner.bundleID) {
            return (.protected, reasons + ["\(owner.name) is running. Quit it to clean this safely."])
        }
        if candidate.scope == .item, let newest = candidate.size.newestModification,
           context.now.timeIntervalSince(newest) < activeWindow {
            return (.protected, reasons + ["In use: changed \(newest.relativeDisplay)"])
        }
        return (max(candidate.safety, category.defaultSafety), reasons)
    }

    // MARK: - Execution-time validation

    /// Re-validates a path immediately before removal. Returns current filesystem facts.
    func validateForRemoval(
        path: String,
        expectedIdentity: FileIdentity?,
        rootPath: String,
        allowDatabases: Bool
    ) -> Result<FileSpaceInfo, CleanLocalError> {
        if hardProtectionReason(for: path, allowDatabases: allowDatabases) != nil {
            return .failure(.protectedLocation(path: UserDirectories.abbreviate(path: path)))
        }
        guard let info = FileSpaceInspector.inspect(path: path) else {
            return .failure(.fileNotFound(path: path))
        }
        if info.isSymbolicLink { return .failure(.symbolicLinkRefused(path: path)) }
        if info.isImmutable { return .failure(.fileLocked(path: path)) }
        if let expectedIdentity, expectedIdentity != info.identity {
            return .failure(.fileChangedSinceScan(path: path))
        }
        guard Self.isContained(path: path, in: rootPath) else {
            return .failure(.outsideAuthorizedLocations(path: path))
        }
        if let root = FileSpaceInspector.inspect(path: rootPath), root.device != info.device {
            return .failure(.outsideAuthorizedLocations(path: path)) // crosses a mount point
        }
        return .success(info)
    }

    /// `true` when `path` (with symlinked parents resolved) is strictly inside `rootPath`.
    static func isContained(path: String, in rootPath: String) -> Bool {
        let root = URL(fileURLWithPath: rootPath).resolvingSymlinksInPath().path
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().resolvingSymlinksInPath().path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        return (parent == root || parent.hasPrefix(rootPrefix)) && (path as NSString).standardizingPath != root
    }
}
