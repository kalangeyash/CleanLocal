import Foundation

/// Resolves the user's real home folders.
///
/// Inside the App Sandbox `NSHomeDirectory()` points at the app container, so the real
/// home is read from the password database. These paths are only used to *suggest*
/// locations in an open panel and to abbreviate paths for display. Access is always
/// granted by the user through `NSOpenPanel`.
enum UserDirectories {
    static let realHomePath: String = {
        if let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir {
            return String(cString: directory)
        }
        return NSHomeDirectory()
    }()

    static var realHomeURL: URL { URL(fileURLWithPath: realHomePath, isDirectory: true) }

    static var desktop: URL { realHomeURL.appendingPathComponent("Desktop", isDirectory: true) }
    static var downloads: URL { realHomeURL.appendingPathComponent("Downloads", isDirectory: true) }
    static var pictures: URL { realHomeURL.appendingPathComponent("Pictures", isDirectory: true) }
    static var movies: URL { realHomeURL.appendingPathComponent("Movies", isDirectory: true) }

    /// Replaces the real home prefix with `~` for compact display.
    static func abbreviate(path: String) -> String {
        if path == realHomePath { return "~" }
        if path.hasPrefix(realHomePath + "/") {
            return "~" + path.dropFirst(realHomePath.count)
        }
        return path
    }
}
