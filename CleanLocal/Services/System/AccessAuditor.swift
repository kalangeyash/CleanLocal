import Foundation

/// Whether CleanLocal can currently read and modify a location.
struct AccessCheck: Identifiable, Codable, Hashable, Sendable {
    var id: String { path }
    let title: String
    let path: String
    let exists: Bool
    let readable: Bool
    let writable: Bool
    let error: String?

    var statusTitle: String {
        if !exists { return "Not present" }
        if readable && writable { return "Accessible" }
        if readable { return "Read-only" }
        return "Needs permission"
    }
}

/// Probes the locations cleanup features rely on, without modifying anything.
///
/// macOS (App Sandbox and privacy protections) decides what is reachable; this only reports
/// it so the UI can explain what to grant and why. It never probes other apps' data, so it
/// can't trigger privacy prompts, and it only runs when the user opens an access screen.
enum AccessAuditor {
    static func standardLocations(home: String) -> [(String, String)] {
        [
            ("Application caches", home + "/Library/Caches"),
            ("Logs", home + "/Library/Logs"),
            ("Diagnostic reports", home + "/Library/Logs/DiagnosticReports"),
            ("Xcode DerivedData", home + "/Library/Developer/Xcode/DerivedData"),
            ("npm cache", home + "/.npm"),
            ("Gradle cache", home + "/.gradle"),
            ("Downloads", home + "/Downloads"),
            ("Trash", home + "/.Trash"),
            ("Application Support", home + "/Library/Application Support"),
            ("Launch agents", home + "/Library/LaunchAgents"),
            ("Applications", "/Applications"),
        ]
    }

    static func audit(home: String = UserDirectories.realHomePath) -> [AccessCheck] {
        standardLocations(home: home).map { check(title: $0.0, path: $0.1) }
    }

    static func check(title: String, path: String) -> AccessCheck {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        var readable = false
        var errorDescription: String?
        if exists {
            do {
                if isDirectory.boolValue {
                    _ = try FileManager.default.contentsOfDirectory(atPath: path)
                } else {
                    _ = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)).close()
                }
                readable = true
            } catch {
                errorDescription = (error as NSError).localizedDescription
            }
        }
        return AccessCheck(
            title: title,
            path: path,
            exists: exists || errorDescription != nil,
            readable: readable,
            writable: readable && access(path, W_OK) == 0,
            error: errorDescription
        )
    }

    /// Writes an access report into the app container (used for diagnostics).
    static func writeReport(to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(audit()) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
