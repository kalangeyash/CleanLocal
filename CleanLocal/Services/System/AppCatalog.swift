import AppKit
import Foundation

/// Answers "which app owns this?" using LaunchServices — the same registry Finder uses.
protocol AppCataloging: Sendable {
    /// Whether an application with this bundle identifier is installed.
    func isInstalled(bundleID: String) -> Bool
    /// The user-facing application name, if installed.
    func displayName(bundleID: String) -> String?
}

extension AppCataloging {
    func owner(bundleID: String, running: Set<String>) -> AppOwner {
        AppOwner(
            bundleID: bundleID,
            name: displayName(bundleID: bundleID) ?? BundleIdentifier.prettyName(for: bundleID),
            isInstalled: isInstalled(bundleID: bundleID),
            isRunning: running.contains(bundleID)
        )
    }
}

/// Live implementation backed by `NSWorkspace` (thread-safe, memoized).
final class SystemAppCatalog: AppCataloging, @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: URL?] = [:]

    private func applicationURL(for bundleID: String) -> URL? {
        if let cached = lock.withLock({ cache[bundleID] }) { return cached }
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        lock.withLock { cache[bundleID] = url }
        return url
    }

    func isInstalled(bundleID: String) -> Bool { applicationURL(for: bundleID) != nil }

    func displayName(bundleID: String) -> String? {
        guard let url = applicationURL(for: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
}

/// Bundle-identifier heuristics for folder and file names found in `~/Library`.
enum BundleIdentifier {
    /// Extracts a bundle identifier from a Library entry name, or `nil` if the name
    /// doesn't look like one. Handles `.plist`/`.savedState` suffixes, `group.` prefixes and
    /// Team-ID-prefixed group containers (`ABCDE12345.com.example.shared`).
    static func extract(from name: String) -> String? {
        var candidate = name
        for suffix in [".plist", ".savedState", ".binarycookies"] where candidate.hasSuffix(suffix) {
            candidate = String(candidate.dropLast(suffix.count))
        }
        if candidate.hasPrefix("group.") { candidate = String(candidate.dropFirst(6)) }
        let parts = candidate.split(separator: ".")
        if parts.count >= 4, let first = parts.first, first.count == 10,
           first.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            candidate = parts.dropFirst().joined(separator: ".")
        }
        let components = candidate.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3,
              components.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" } }),
              let tld = components.first, tld.count <= 6, tld.allSatisfy(\.isLowercase)
        else { return nil }
        return candidate
    }

    static func isApple(_ bundleID: String) -> Bool {
        bundleID.lowercased().hasPrefix("com.apple.")
    }

    /// "com.example.FancyEditor" → "FancyEditor".
    static func prettyName(for bundleID: String) -> String {
        let last = bundleID.split(separator: ".").last.map(String.init) ?? bundleID
        return last.isEmpty ? bundleID : last
    }
}

/// An installed application bundle.
struct InstalledApp: Identifiable, Hashable, Sendable {
    var id: String { bundleID }
    let bundleID: String
    let name: String
    let url: URL
    let version: String?
}

enum InstalledAppsScanner {
    /// Enumerates `/Applications` (and `~/Applications` when readable), one level deep plus
    /// `Utilities`. Reads only each bundle's Info.plist.
    static func scan(additionalRoots: [URL] = []) -> [InstalledApp] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Applications/Utilities")] + additionalRoots
        var apps: [String: InstalledApp] = [:]
        for root in roots {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { continue }
            for name in names where name.hasSuffix(".app") {
                let url = root.appendingPathComponent(name)
                guard let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else { continue }
                let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? String(name.dropLast(4))
                let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                apps[bundleID] = InstalledApp(bundleID: bundleID, name: displayName, url: url, version: version)
            }
        }
        return apps.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
