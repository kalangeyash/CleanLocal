import Foundation

/// Decides which paths CleanLocal must never scan into or remove.
///
/// This is a defense-in-depth layer on top of the App Sandbox: even if the user
/// authorizes a broad folder, system locations, application bundles and managed
/// libraries (such as `.photoslibrary`) are always off-limits to filesystem operations.
struct ProtectedPathPolicy: Sendable {
    /// Absolute path prefixes that are protected along with everything beneath them.
    let protectedPrefixes: [String]
    /// Package/bundle extensions whose contents must never be touched directly.
    let protectedPackageExtensions: Set<String>

    static let standard = ProtectedPathPolicy(
        protectedPrefixes: [
            "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin", "/opt",
            "/private", "/etc", "/var", "/tmp", "/cores", "/dev", "/Volumes/Recovery",
            UserDirectories.realHomePath + "/Library",
            UserDirectories.realHomePath + "/Applications",
            UserDirectories.realHomePath + "/.Trash",
        ],
        protectedPackageExtensions: defaultPackageExtensions
    )

    static let defaultPackageExtensions: Set<String> = [
        // Applications and code
        "app", "appex", "framework", "bundle", "plugin", "kext", "xpc", "prefpane", "qlgenerator",
        "mdimporter", "saver", "pkg", "mpkg", "xcodeproj", "xcworkspace", "xcarchive",
        // Managed media libraries (must be modified only through their own apps / APIs)
        "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary",
        "tvlibrary", "imovielibrary", "theater", "fcpbundle", "logicx", "band", "lrdata", "lrlibrary",
    ]

    init(protectedPrefixes: [String], protectedPackageExtensions: Set<String> = defaultPackageExtensions) {
        self.protectedPrefixes = protectedPrefixes.map { ($0 as NSString).standardizingPath }
        self.protectedPackageExtensions = protectedPackageExtensions
    }

    /// `true` if `path` is a protected location or lives inside one.
    func isProtected(path: String) -> Bool {
        protectionReason(for: path) != nil
    }

    /// A human readable reason when `path` is protected, otherwise `nil`.
    func protectionReason(for path: String) -> String? {
        let standardized = (path as NSString).standardizingPath
        guard standardized.hasPrefix("/") else { return "Only absolute paths are allowed" }
        if standardized == "/" { return "The startup disk root is protected" }

        for prefix in protectedPrefixes where standardized == prefix || standardized.hasPrefix(prefix + "/") {
            return "Inside protected location \(UserDirectories.abbreviate(path: prefix))"
        }

        for component in standardized.split(separator: "/") {
            let fileExtension = (String(component) as NSString).pathExtension.lowercased()
            if !fileExtension.isEmpty, protectedPackageExtensions.contains(fileExtension) {
                return "Inside a protected package (.\(fileExtension))"
            }
        }
        return nil
    }
}
