import XCTest
@testable import CleanLocal

/// Builds a realistic fake home folder and runs the real rules, scanner and executor on it.
final class CleanupScannerTests: XCTestCase {
    private var temp: TemporaryDirectory!
    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    private func buildHome() throws {
        // App caches: installed, uninstalled, Apple, unnamed; one file is "in use" (fresh).
        try temp.file("Library/Caches/com.example.Editor/blob.bin", bytes: 50_000, ageDays: 2)
        try temp.file("Library/Caches/com.example.Editor/fresh.bin", bytes: 10_000)
        try temp.file("Library/Caches/com.example.Editor/tmp/scratch.bin", bytes: 7_000, ageDays: 2)
        try temp.age("Library/Caches/com.example.Editor/tmp", days: 2)
        try temp.file("Library/Caches/com.gone.OldApp/cache.db", bytes: 20_000, ageDays: 10)
        try temp.file("Library/Caches/com.apple.Something/x.bin", bytes: 5_000, ageDays: 10)
        try temp.file("Library/Caches/UnnamedFolder/y.bin", bytes: 5_000, ageDays: 10)
        // Browser + developer caches (claimed, never double-counted as app caches).
        try temp.file("Library/Caches/Google/Chrome/Default/Cache/Cache_Data/data_1", bytes: 30_000, ageDays: 1)
        try temp.file("Library/Caches/ms-playwright/chromium-1/chrome", bytes: 40_000, ageDays: 3)
        try temp.file(".npm/_cacache/index-v5/aa", bytes: 25_000, ageDays: 5)
        try temp.file("Library/Developer/Xcode/DerivedData/MyApp-abcdef/Build/out.o", bytes: 60_000, ageDays: 1)
        try temp.age("Library/Developer/Xcode/DerivedData/MyApp-abcdef", days: 1)
        try temp.file("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A)/Symbols/a", bytes: 80_000, ageDays: 40)
        try temp.age("Library/Developer/Xcode/iOS DeviceSupport/18.0 (22A)", days: 40)
        // Logs and crash reports: old vs recent.
        try temp.file("Library/Logs/com.example.Editor/old.log", bytes: 9_000, ageDays: 60)
        try temp.file("Library/Logs/com.example.Editor/new.log", bytes: 9_000, ageDays: 1)
        try temp.file("Library/Logs/DiagnosticReports/Editor-2024-01-01-101010.ips", bytes: 3_000, ageDays: 90)
        try temp.file("Library/Logs/DiagnosticReports/Editor-2026-11-01-101010.ips", bytes: 3_000, ageDays: 2)
        // Downloads: stale partial download and an old installer.
        try temp.file("Downloads/movie.mp4.crdownload", bytes: 12_000, ageDays: 3)
        try temp.file("Downloads/Editor-Installer.dmg", bytes: 70_000, ageDays: 30)
        try temp.file("Downloads/report.pdf", bytes: 4_000, ageDays: 30)
        // Leftovers: uninstalled vs installed app data, shared group container.
        try temp.file("Library/Application Support/com.gone.OldApp/db.sqlite", bytes: 15_000, ageDays: 100)
        try temp.file("Library/Application Support/com.example.Editor/settings.json", bytes: 1_000, ageDays: 100)
        try temp.file("Library/Group Containers/ABCDE12345.com.example.shared/x", bytes: 1_000, ageDays: 100)
        try temp.file("Library/Preferences/com.gone.OldApp.plist", bytes: 500, ageDays: 100)
        // Protected: credentials must never appear as cleanable.
        try temp.file("Library/Keychains/login.keychain-db", bytes: 2_000, ageDays: 10)
        try temp.file(".ssh/id_ed25519", bytes: 400, ageDays: 10)
    }

    private func scan(running: Set<String> = [], projectRoots: [URL] = []) async throws -> CleanupScanResult {
        let context = makeRuleContext(
            home: temp.url, projectRoots: projectRoots,
            installed: ["com.example.Editor": "Editor", "com.example.Other": "Other"],
            running: running,
            installedApps: [InstalledApp(bundleID: "com.example.Editor", name: "Editor", url: URL(fileURLWithPath: "/Applications/Editor.app"), version: "1.0")]
        )
        let groups = Set(CleanupGroup.allCases).subtracting([.userFiles])
        return try await CleanupScanner(engine: temp.engine).scan(groups: groups, context: context)
    }

    private func candidate(_ result: CleanupScanResult, _ suffix: String) -> CleanupCandidate? {
        result.candidates.first { $0.url.path.hasSuffix(suffix) }
    }

    func testClassifiesRealCategoriesWithExplanations() async throws {
        try buildHome()
        let result = try await scan()

        let editorCache = try XCTUnwrap(candidate(result, "Caches/com.example.Editor"))
        XCTAssertEqual(editorCache.categoryID, "app-caches")
        XCTAssertEqual(editorCache.safety, .safe)
        XCTAssertEqual(editorCache.size.logicalSize, 50_000, "fresh files and the tmp folder aren't counted as cache contents")

        XCTAssertEqual(candidate(result, "Caches/com.example.Editor/tmp")?.categoryID, "app-temporary")
        XCTAssertEqual(candidate(result, "Caches/com.gone.OldApp")?.owner?.isInstalled, false)
        XCTAssertEqual(candidate(result, "Caches/com.apple.Something")?.safety, .review)
        XCTAssertEqual(candidate(result, "Caches/UnnamedFolder")?.safety, .review)

        XCTAssertNil(candidate(result, "Library/Caches/Google"), "browser caches are only reported by the browser rule")
        XCTAssertEqual(candidate(result, "Default/Cache")?.categoryID, "browser-chrome")
        XCTAssertEqual(candidate(result, "Caches/ms-playwright")?.categoryID, "playwright-browsers")
        XCTAssertEqual(candidate(result, ".npm/_cacache")?.categoryID, "npm-cache")
        XCTAssertEqual(candidate(result, "DerivedData/MyApp-abcdef")?.displayName, "MyApp")
        XCTAssertEqual(candidate(result, "DerivedData/MyApp-abcdef")?.safety, .safe)
        XCTAssertEqual(candidate(result, "18.0 (22A)")?.safety, .review)

        let logs = try XCTUnwrap(candidate(result, "Logs/com.example.Editor"))
        XCTAssertEqual(logs.size.logicalSize, 9_000, "only logs older than the threshold count")
        XCTAssertNotNil(candidate(result, "Editor-2024-01-01-101010.ips"))
        XCTAssertNil(candidate(result, "Editor-2026-11-01-101010.ips"), "recent crash reports are kept")

        XCTAssertEqual(candidate(result, "movie.mp4.crdownload")?.safety, .safe)
        let installer = try XCTUnwrap(candidate(result, "Editor-Installer.dmg"))
        XCTAssertEqual(installer.safety, .review)
        XCTAssertTrue(installer.reasons.contains { $0.contains("installed") })
        XCTAssertNil(candidate(result, "report.pdf"))

        XCTAssertEqual(candidate(result, "Application Support/com.gone.OldApp")?.safety, .review)
        XCTAssertNil(candidate(result, "Application Support/com.example.Editor"), "installed apps' data is not a leftover")
        XCTAssertEqual(candidate(result, "ABCDE12345.com.example.shared")?.safety, .protected, "shared with an installed app")
        XCTAssertEqual(candidate(result, "com.gone.OldApp.plist")?.categoryID, "leftover-preferences")

        XCTAssertFalse(result.candidates.contains { $0.url.path.contains("Keychains") || $0.url.path.contains(".ssh") })
        XCTAssertEqual(Set(result.candidates.map(\.id)).count, result.candidates.count, "no item is reported twice")
        for item in result.candidates where item.safety != .safe {
            XCTAssertFalse(item.reasons.isEmpty && item.safety == .protected, "protected items explain why")
        }
    }

    func testRunningAppsAndBrowsersAreProtected() async throws {
        try buildHome()
        let result = try await scan(running: ["com.example.Editor", "com.google.Chrome"])
        XCTAssertEqual(candidate(result, "Caches/com.example.Editor")?.safety, .protected)
        XCTAssertEqual(candidate(result, "Default/Cache")?.safety, .protected)
        XCTAssertTrue(candidate(result, "Default/Cache")?.reasons.contains { $0.contains("running") } ?? false)
    }

    func testProjectArtifactsOnlyInChosenFolders() async throws {
        try buildHome()
        let projects = try temp.makeDirectory("Code")
        try temp.file("Code/web/package.json", bytes: 30)
        try Data(#"{"name":"my-web"}"#.utf8).write(to: projects.appendingPathComponent("web/package.json"))
        try temp.file("Code/web/node_modules/react/index.js", bytes: 40_000, ageDays: 3)
        try temp.file("Code/web/node_modules/nested/package.json", bytes: 30)
        try temp.file("Code/web/node_modules/nested/node_modules/x/index.js", bytes: 10)
        try temp.file("Code/rusty/Cargo.toml", bytes: 30)
        try temp.file("Code/rusty/target/debug/app", bytes: 50_000, ageDays: 3)
        try temp.file("Code/py/.venv/pyvenv.cfg", bytes: 30, ageDays: 3)
        try temp.file("Code/py/.venv/lib/site.py", bytes: 3_000, ageDays: 3)
        try temp.file("Elsewhere/proj/package.json", bytes: 30)
        try temp.file("Elsewhere/proj/node_modules/a.js", bytes: 9_000, ageDays: 3)
        for path in ["Code/web/node_modules", "Code/rusty/target", "Code/py/.venv"] { try temp.age(path, days: 3) }

        let none = try await scan()
        XCTAssertFalse(none.candidates.contains { $0.categoryID == "node-modules" }, "no developer folders chosen → no search")

        let result = try await scan(projectRoots: [projects])
        let modules = result.candidates.filter { $0.categoryID == "node-modules" }
        XCTAssertEqual(modules.map(\.displayName), ["my-web"], "nested node_modules aren't separate items; other folders aren't searched")
        XCTAssertEqual(modules.first?.safety, .review)
        XCTAssertEqual(candidate(result, "rusty/target")?.categoryID, "build-artifacts")
        XCTAssertEqual(candidate(result, "py/.venv")?.categoryID, "python-venvs")
        XCTAssertEqual(candidate(result, "rusty/target")?.rootPath, projects.path)
    }

    func testUnreadableLocationsBecomeIssuesNotFailures() async throws {
        try buildHome()
        let logs = temp.url.appendingPathComponent("Library/Logs")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: logs.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: logs.path) }
        let result = try await scan()
        XCTAssertTrue(result.issues.contains { $0.path.hasSuffix("Library/Logs") })
        XCTAssertNotNil(candidate(result, "Caches/com.example.Editor"), "other categories still scan")
    }
}

final class CleanupExecutionTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var remover: RecordingRemover!
    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
        remover = RecordingRemover(trash: temp.url.appendingPathComponent("FakeTrash"))
    }
    override func tearDown() { temp.cleanUp() }

    private func candidate(_ relative: String, category: String, scope: CleanupScope, safety: SafetyLevel = .safe,
                           owner: AppOwner? = nil, root: String? = nil) throws -> CleanupCandidate {
        let url = temp.url.appendingPathComponent(relative)
        let info = try XCTUnwrap(FileSpaceInspector.inspect(url: url))
        let size = try CleanupEligibility.measure(url, scope: scope, categoryID: category, now: .now, activeWindow: 15 * 60)
        return CleanupCandidate(id: url.path, url: url, categoryID: category, displayName: url.lastPathComponent, scope: scope,
                                safety: safety, reasons: [], owner: owner, isDirectory: info.isDirectory, size: size,
                                identity: info.identity, rootPath: root ?? temp.url.path)
    }

    private var executor: CleanupExecutionService { CleanupExecutionService(engine: temp.engine, remover: remover) }

    func testContentsScopeKeepsFolderAndRecentFiles() async throws {
        try temp.file("Library/Caches/com.example.app/old.bin", bytes: 1_000, ageDays: 2)
        try temp.file("Library/Caches/com.example.app/fresh.bin", bytes: 1_000)
        let item = try candidate("Library/Caches/com.example.app", category: "app-caches", scope: .contents)
        let report = await executor.execute([.init(candidate: item, method: .moveToTrash)], runningBundleIDs: [])

        let result = try XCTUnwrap(report.results.first)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertEqual(result.skippedFiles, 1)
        XCTAssertEqual(result.status, .partial)
        XCTAssertEqual(result.trashedPaths.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path), "the cache folder itself is kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.appendingPathComponent("fresh.bin").path))
    }

    func testFilesOlderThanScopeRemovesOnlyOldFilesAndKeepsFolders() async throws {
        try temp.file("Library/Logs/app/sub/old.log", bytes: 500, ageDays: 60)
        try temp.file("Library/Logs/app/new.log", bytes: 500, ageDays: 1)
        let item = try candidate("Library/Logs/app", category: "user-logs", scope: .filesOlderThan(days: 30))
        let report = await executor.execute([.init(candidate: item, method: .deletePermanently)], runningBundleIDs: [])
        XCTAssertEqual(report.results.first?.removedFiles, 1)
        XCTAssertGreaterThan(report.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("Library/Logs/app/sub").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.url.appendingPathComponent("Library/Logs/app/new.log").path))
    }

    func testRefusesProtectedRunningReplacedAndDisallowedImmediateDeletion() async throws {
        try temp.file("Library/Caches/com.example.app/a.bin", bytes: 100, ageDays: 2)
        try temp.file("Downloads/Setup.dmg", bytes: 100, ageDays: 30)
        let owner = AppOwner(bundleID: "com.example.app", name: "Example", isInstalled: true, isRunning: false)

        let protected = try candidate("Library/Caches/com.example.app", category: "app-caches", scope: .contents, safety: .protected)
        let running = try candidate("Library/Caches/com.example.app", category: "app-caches", scope: .contents, owner: owner)
        let installer = try candidate("Downloads/Setup.dmg", category: "installers", scope: .item, safety: .review)

        let report = await executor.execute([
            .init(candidate: protected, method: .moveToTrash),
            .init(candidate: running, method: .moveToTrash),
            .init(candidate: installer, method: .deletePermanently),
        ], runningBundleIDs: ["com.example.app"])
        XCTAssertEqual(report.results.map(\.status), [.failed, .failed, .failed])
        XCTAssertTrue(remover.trashed.isEmpty && remover.deleted.isEmpty, "nothing touched")

        // Replaced between scan and cleanup.
        let original = try candidate("Downloads/Setup.dmg", category: "installers", scope: .item, safety: .review)
        try FileManager.default.removeItem(at: original.url)
        try temp.file("Downloads/Setup.dmg", bytes: 100, ageDays: 30)
        let replaced = await executor.execute([.init(candidate: original, method: .moveToTrash)], runningBundleIDs: [])
        XCTAssertEqual(replaced.results.first?.status, .failed)
        XCTAssertTrue(remover.trashed.isEmpty)
    }

    func testPartialFailuresAreReportedPerFile() async throws {
        try temp.file("Library/Caches/com.example.app/a.bin", bytes: 100, ageDays: 2)
        try temp.file("Library/Caches/com.example.app/b.bin", bytes: 100, ageDays: 2)
        remover.failingNames = ["b.bin"]
        let item = try candidate("Library/Caches/com.example.app", category: "app-caches", scope: .contents)
        let report = await executor.execute([.init(candidate: item, method: .moveToTrash)], runningBundleIDs: [])
        let result = try XCTUnwrap(report.results.first)
        XCTAssertEqual(result.removedFiles, 1)
        XCTAssertEqual(result.status, .partial)
        XCTAssertFalse(result.errors.isEmpty)
        XCTAssertEqual(report.failures.count, 1, "a partial cleanup is never reported as complete success")
    }

    func testItemScopeRefusesRecentlyChangedFolders() async throws {
        try temp.file("Library/Developer/Xcode/DerivedData/App-x/Build/new.o", bytes: 100)
        let item = try candidate("Library/Developer/Xcode/DerivedData/App-x", category: "xcode-derived-data", scope: .item)
        let report = await executor.execute([.init(candidate: item, method: .moveToTrash)], runningBundleIDs: [])
        XCTAssertEqual(report.results.first?.status, .failed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: item.url.path))
    }
}

final class TrashServiceTests: XCTestCase {
    private var temp: TemporaryDirectory!
    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testListsAndEmptiesOnlyDirectChildrenOfTheTrash() async throws {
        let trash = try temp.makeDirectory(".Trash")
        try temp.file(".Trash/old.mov", bytes: 5_000)
        try temp.file(".Trash/Folder/inner.txt", bytes: 1_000)
        let outside = try temp.file("Documents/keep.txt", bytes: 100)
        try FileManager.default.createSymbolicLink(at: trash.appendingPathComponent("link"), withDestinationURL: outside)

        let service = TrashService()
        let (entries, issues) = await service.entries(in: [trash])
        XCTAssertTrue(issues.isEmpty)
        XCTAssertEqual(Set(entries.map(\.name)), ["old.mov", "Folder", "link"])

        let results = await service.permanentlyDelete(entries)
        XCTAssertTrue(results.allSatisfy { $0.error == nil })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: trash.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "a symlink's target is never touched")

        let refused = await service.deleteTrashedItems([outside.path, trash.appendingPathComponent("../Documents/keep.txt").path])
        XCTAssertTrue(refused.allSatisfy { $0.error != nil })
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path), "only items inside a Trash folder can be emptied")
    }

    func testTrashFolderRecognition() {
        XCTAssertTrue(TrashService.isTrashFolder("/Users/me/.Trash"))
        XCTAssertTrue(TrashService.isTrashFolder("/Volumes/Drive/.Trashes/501"))
        XCTAssertFalse(TrashService.isTrashFolder("/Users/me/Documents"))
        XCTAssertFalse(TrashService.isTrashFolder("/Volumes/Drive/.Trashes"))
    }
}

final class DiskUsageTests: XCTestCase {
    private var temp: TemporaryDirectory!
    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testTreeSumsAggregatesSmallFilesAndCountsHardLinksOnce() async throws {
        let big = try temp.file("Home/Movies/big.mov", bytes: 3_000_000)
        try FileManager.default.linkItem(at: big, to: temp.url.appendingPathComponent("Home/Movies/big-link.mov"))
        for index in 0..<5 { try temp.file("Home/Notes/n\(index).txt", bytes: 1_000) }
        try temp.file("Home/Tool.app/Contents/MacOS/tool", bytes: 2_000_000)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("Home/loop"), withDestinationURL: temp.url.appendingPathComponent("Home"))

        let tree = try await DiskUsageScanner().scan(root: temp.url.appendingPathComponent("Home"))
        let files = tree.files
        XCTAssertEqual(files.filter { $0.name.hasPrefix("big") }.count, 1, "hard links are counted once")
        XCTAssertEqual(files.first { $0.name == "big.mov" || $0.name == "big-link.mov" }?.category, .videos)
        let app = try XCTUnwrap(files.first { $0.name == "Tool.app" })
        XCTAssertEqual(app.kind, .package)
        XCTAssertTrue(tree.nodes.contains { $0.kind == .smallFiles && $0.fileCount == 5 })
        XCTAssertGreaterThanOrEqual(tree.root.logicalSize, 5_000_000 + 5_000)
        XCTAssertLessThan(tree.root.logicalSize, 6_000_000, "symlink loop not followed, link not double counted")
        XCTAssertEqual(tree.breadcrumb(to: app.id).first?.id, tree.rootID)
    }

    func testFileDuplicatesAreCloneAware() async throws {
        let a = try temp.file("Home/a.bin", bytes: 2_000_000)
        try temp.makeDirectory("Home/Downloads")
        try FileManager.default.copyItem(at: a, to: temp.url.appendingPathComponent("Home/Downloads/a copy.bin"))
        let cloned = temp.url.appendingPathComponent("Home/clone.bin")
        let canClone = clonefile(a.path, cloned.path, 0) == 0
        // Same size, different content: must not be grouped.
        try temp.writeData(Data(repeating: 1, count: 2_000_000), to: "Home/other.bin")

        let tree = try await DiskUsageScanner().scan(root: temp.url.appendingPathComponent("Home"))
        let groups = try await FileDuplicateFinder.find(in: tree.files)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.files.count, canClone ? 3 : 2)
        XCTAssertFalse(group.keeperPath.contains("/Downloads/"), "keeps the copy outside Downloads")
        if canClone {
            XCTAssertTrue(group.involvesClones)
            XCTAssertLessThan(group.reclaimableBytes, 2 * 2_000_000, "the clone frees nothing")
        }
    }

    func testBreakdownPartitionsWithoutDoubleCounting() async throws {
        try temp.file("Home/Downloads/setup.dmg", bytes: 2_000_000)
        try temp.file("Home/Library/Caches/com.example/x.bin", bytes: 1_500_000)
        try temp.file("Home/Library/Caches/ms-playwright/c.bin", bytes: 1_200_000)
        try temp.file("Home/.npm/_cacache/y.bin", bytes: 1_100_000)
        try temp.file("Home/Code/main.swift", bytes: 1_300_000)
        let home = temp.url.appendingPathComponent("Home")
        let tree = try await DiskUsageScanner().scan(root: home)
        let index = Dictionary(tree.nodes.filter { $0.kind != .smallFiles }.map { ($0.path, $0.id) }, uniquingKeysWith: { a, _ in a })
        let areas = StorageBreakdownService.areas(tree: tree, pathIndex: index, homePath: home.path, applicationsBytes: nil,
                                                  systemVolumeUsed: nil, dataVolume: nil, purgeable: nil)
        let byID = Dictionary(uniqueKeysWithValues: areas.map { ($0.id, $0.bytes) })
        XCTAssertNotNil(byID["downloads"])
        XCTAssertNotNil(byID["dev-caches"], "Playwright and npm count as developer caches")
        XCTAssertNotNil(byID["app-caches"])
        XCTAssertLessThan(byID["app-caches"] ?? 0, 1_500_000 + 1_200_000, "developer caches are not double counted as app caches")
        XCTAssertEqual(areas.reduce(Int64(0)) { $0 + $1.bytes }, tree.root.allocatedSize, "areas add up to the Home folder exactly")
    }
}

final class MediaSpaceAccountingTests: XCTestCase {
    func testClonedDuplicateCopiesFreeNothing() {
        var keeper = makeItem(id: "a", size: 1_000, contentHash: "h")
        var clone = makeItem(id: "b", size: 1_000, contentHash: "h")
        keeper.cloneID = 42
        clone.cloneID = 42
        clone.reclaimableSize = 0
        let group = DuplicateGroup(id: "g", kind: .exact, items: [keeper, clone], suggestedKeeperID: keeper.id, similarity: 1)
        XCTAssertEqual(group.reclaimableBytes, 0)
        XCTAssertTrue(group.involvesClones)
        XCTAssertEqual(StorageAnalyticsService.reclaimableBytes(in: [group]), 0)
    }

    func testUnknownPhotosSizesAreNotShownAsZero() {
        let unknown = makeItem(id: "p", size: 0, photos: true)
        XCTAssertFalse(unknown.hasKnownSize)
        XCTAssertEqual(unknown.displaySize, "Unknown size")
        XCTAssertTrue(makeItem(id: "f", size: 0).hasKnownSize, "empty regular files really are 0 bytes")
    }

    func testProbableDuplicatesMatchMetadataAndNeverCountAsSavings() async throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let a = makeItem(id: "a", size: 0, created: date, width: 4032, height: 3024, photos: true)
        let b = makeItem(id: "b", size: 0, created: date, width: 4032, height: 3024, photos: true)
        let c = makeItem(id: "c", size: 0, created: date.addingTimeInterval(5), width: 4032, height: 3024, photos: true)
        let groups = try await DuplicateDetectionService().probableDuplicates(among: [a, b, c])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.kind, .probable)
        XCTAssertEqual(Set(groups.first?.items.map(\.id) ?? []), [a.id, b.id])
        XCTAssertTrue(DuplicateSelectionPolicy.autoSelection(for: []).isEmpty)

        let result = try await DuplicateDetectionService().findExactDuplicates(in: [a, b, c])
        XCTAssertTrue(result.groups.isEmpty, "probable matches are never exact duplicates")
        XCTAssertEqual(result.probableGroups.count, 1)
    }
}
