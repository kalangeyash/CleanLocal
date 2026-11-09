import Foundation
@testable import CleanLocal

/// LaunchServices stand-in with a fixed set of installed apps.
struct FakeAppCatalog: AppCataloging {
    var installed: [String: String] = [:]

    func isInstalled(bundleID: String) -> Bool { installed[bundleID] != nil }
    func displayName(bundleID: String) -> String? { installed[bundleID] }
}

/// Records removals and moves "trashed" files into a private folder (never the real Trash).
final class RecordingRemover: FileRemoving, @unchecked Sendable {
    let trash: URL
    private let lock = NSLock()
    private(set) var trashed: [String] = []
    private(set) var deleted: [String] = []
    var failingNames: Set<String> = []

    init(trash: URL) { self.trash = trash }

    func moveToTrash(_ url: URL) throws -> URL? {
        if failingNames.contains(url.lastPathComponent) { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let destination = trash.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        lock.withLock { trashed.append(url.path) }
        return destination
    }

    func deletePermanently(_ url: URL) throws {
        if failingNames.contains(url.lastPathComponent) { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
        try FileManager.default.removeItem(at: url)
        lock.withLock { deleted.append(url.path) }
    }
}

extension TemporaryDirectory {
    /// Writes a file and back-dates its modification time.
    @discardableResult
    func file(_ relativePath: String, bytes: Int = 4_096, ageDays: Double = 0) throws -> URL {
        let url = try writeData(Data(repeating: 0xAB, count: bytes), to: relativePath)
        if ageDays > 0 {
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageDays * 86_400)], ofItemAtPath: url.path)
        }
        return url
    }

    /// Back-dates a directory and everything in it.
    func age(_ relativePath: String, days: Double) throws {
        let root = url.appendingPathComponent(relativePath)
        let date = Date().addingTimeInterval(-days * 86_400)
        if let enumerator = FileManager.default.enumerator(atPath: root.path) {
            while let child = enumerator.nextObject() as? String {
                try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.appendingPathComponent(child).path)
            }
        }
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: root.path)
    }

    var engine: SafetyPolicyEngine { SafetyPolicyEngine(homePath: url.path) }
}

func makeRuleContext(
    home: URL,
    projectRoots: [URL] = [],
    installed: [String: String] = [:],
    running: Set<String> = [],
    installedApps: [InstalledApp] = []
) -> RuleContext {
    RuleContext(
        layout: HomeLayout(home: home, projectRoots: projectRoots),
        apps: FakeAppCatalog(installed: installed),
        installedApps: installedApps,
        running: running,
        now: .now,
        thresholds: CleanupThresholds(),
        ownBundleID: "com.yourdomain.cleanlocal"
    )
}
