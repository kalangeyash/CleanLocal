import XCTest
@testable import CleanLocal

final class SafetyPolicyEngineTests: XCTestCase {
    private let engine = SafetyPolicyEngine(homePath: "/Users/tester")

    func testSystemAndOutsideHomeLocationsAreProtected() {
        for path in ["/System/Library/Caches/x", "/Library/Caches/com.apple.x", "/usr/local/lib/a", "/private/var/folders/x/T/a",
                     "/Applications/Xcode.app", "/Users/other/Library/Caches/x", "/", "relative/path"] {
            XCTAssertNotNil(engine.hardProtectionReason(for: path), path)
        }
    }

    func testCredentialsPersonalDataAndTopLevelFoldersAreProtected() {
        for path in [
            "/Users/tester/Library/Keychains/login.keychain-db", "/Users/tester/.ssh/id_ed25519", "/Users/tester/project/.aws/credentials",
            "/Users/tester/Library/Cookies/Cookies.binarycookies", "/Users/tester/Library/Mail/V10", "/Users/tester/Library/Safari/History.db",
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/a", "/Users/tester/Library/Developer/Xcode/UserData/Provisioning Profiles/a",
            "/Users/tester/Downloads/cert.p12", "/Users/tester/Downloads/Signing.mobileprovision", "/Users/tester/Documents",
            "/Users/tester/Library", "/Users/tester/.Trash/file", "/Users/tester/Library/Application Support/Google/Chrome/Default/Cookies",
            "/Users/tester/Library/Containers/com.docker.docker/Data", "/Users/tester/code/App.xcodeproj", "/Users/tester/code/.git",
        ] {
            XCTAssertNotNil(engine.hardProtectionReason(for: path), path)
        }
    }

    func testDatabasesAreAllowedOnlyInVerifiedCacheRoots() {
        let path = "/Users/tester/Library/Caches/com.example.app/Cache.db"
        XCTAssertNotNil(engine.hardProtectionReason(for: path, allowDatabases: false))
        XCTAssertNil(engine.hardProtectionReason(for: path, allowDatabases: true))
    }

    func testOrdinaryCacheAndDeveloperPathsAreAllowed() {
        for path in ["/Users/tester/Library/Caches/com.example.app", "/Users/tester/Library/Developer/Xcode/DerivedData/App-abc",
                     "/Users/tester/.npm/_cacache", "/Users/tester/code/web/node_modules", "/Volumes/External/Projects/app/node_modules"] {
            XCTAssertNil(engine.hardProtectionReason(for: path), path)
        }
        XCTAssertNotNil(engine.hardProtectionReason(for: "/Volumes/External"), "volume roots are protected")
    }

    func testClassificationDowngradesRunningRecentLockedAndLinkedItems() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanUp() }
        let engine = temp.engine
        let category = try XCTUnwrap(CleanupCatalog.category(id: "app-caches"))
        let folder = try temp.file("Library/Caches/com.example.app/data.bin", ageDays: 3).deletingLastPathComponent()
        let info = try XCTUnwrap(FileSpaceInspector.inspect(url: folder))
        var size = try DirectorySizer.measure(folder)
        let owner = AppOwner(bundleID: "com.example.app", name: "Example", isInstalled: true, isRunning: true)
        var candidate = CleanupCandidate(id: folder.path, url: folder, categoryID: "app-caches", displayName: "Example",
                                         scope: .contents, safety: .safe, reasons: [], owner: owner, isDirectory: true,
                                         size: size, identity: info.identity, rootPath: temp.url.path)

        XCTAssertEqual(engine.classify(candidate, category: category, info: info, context: .init(runningBundleIDs: [])).0, .safe)
        XCTAssertEqual(engine.classify(candidate, category: category, info: info, context: .init(runningBundleIDs: ["com.example.app"])).0, .protected)

        candidate.scope = .item
        size.newestModification = .now
        candidate.size = size
        let recent = engine.classify(candidate, category: category, info: info, context: .init(runningBundleIDs: []))
        XCTAssertEqual(recent.0, .protected)
        XCTAssertTrue(recent.1.contains { $0.contains("In use") })

        var locked = info
        locked.isImmutable = true
        XCTAssertEqual(engine.classify(candidate, category: category, info: locked, context: .init(runningBundleIDs: [])).0, .protected)
        var link = info
        link.isSymbolicLink = true
        XCTAssertEqual(engine.classify(candidate, category: category, info: link, context: .init(runningBundleIDs: [])).0, .protected)
    }

    func testValidationRejectsReplacedFilesEscapesAndLinks() throws {
        let temp = try TemporaryDirectory()
        defer { temp.cleanUp() }
        let engine = temp.engine
        let root = temp.url.appendingPathComponent("Library/Caches")
        let file = try temp.file("Library/Caches/com.example/a.bin")
        let identity = try XCTUnwrap(FileSpaceInspector.inspect(url: file)).identity

        XCTAssertNoThrow(try engine.validateForRemoval(path: file.path, expectedIdentity: identity, rootPath: root.path, allowDatabases: false).get())

        // Replaced with a different file at the same path.
        try FileManager.default.removeItem(at: file)
        try temp.file("Library/Caches/com.example/a.bin")
        guard case .failure(.fileChangedSinceScan) = engine.validateForRemoval(path: file.path, expectedIdentity: identity, rootPath: root.path, allowDatabases: false) else {
            return XCTFail("A replaced file must be refused")
        }

        // Symlinked folder escaping the root.
        let outside = try temp.file("Elsewhere/secret.bin")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside.deletingLastPathComponent())
        guard case .failure(.outsideAuthorizedLocations) = engine.validateForRemoval(
            path: root.appendingPathComponent("escape/secret.bin").path, expectedIdentity: nil, rootPath: root.path, allowDatabases: false) else {
            return XCTFail("Symlinked parents must not escape the root")
        }
        guard case .failure(.symbolicLinkRefused) = engine.validateForRemoval(
            path: root.appendingPathComponent("escape").path, expectedIdentity: nil, rootPath: root.path, allowDatabases: false) else {
            return XCTFail("Links themselves are refused")
        }
        // The root itself is never removable.
        guard case .failure = engine.validateForRemoval(path: root.path, expectedIdentity: nil, rootPath: root.path, allowDatabases: false) else {
            return XCTFail("The authorized root itself must not be removable")
        }
    }
}

final class FileSpaceInspectorTests: XCTestCase {
    private var temp: TemporaryDirectory!
    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testAPFSClonesReportNoPrivateSpace() throws {
        let original = try temp.file("original.bin", bytes: 2_000_000)
        let clone = temp.url.appendingPathComponent("clone.bin")
        guard clonefile(original.path, clone.path, 0) == 0 else { throw XCTSkip("Volume doesn't support clones") }

        let info = try XCTUnwrap(FileSpaceInspector.inspect(url: clone))
        XCTAssertNotNil(info.privateSize, "APFS reports private size")
        XCTAssertTrue(info.isClone)
        XCTAssertEqual(info.reclaimableSize, 0, "deleting one clone frees nothing while the other exists")
        XCTAssertEqual(info.logicalSize, 2_000_000)
        XCTAssertEqual(FileSpaceInspector.inspect(url: original)?.cloneID, info.cloneID)

        let plain = try XCTUnwrap(FileSpaceInspector.inspect(url: try temp.file("plain.bin", bytes: 2_000_000)))
        XCTAssertGreaterThanOrEqual(plain.reclaimableSize, 2_000_000)
        XCTAssertFalse(plain.isClone)
    }

    func testHardLinksAreFreeToRemoveIndividuallyAndCountedOnce() throws {
        let original = try temp.file("dir/a.bin", bytes: 1_000_000)
        try FileManager.default.linkItem(at: original, to: temp.url.appendingPathComponent("dir/b.bin"))
        let info = try XCTUnwrap(FileSpaceInspector.inspect(url: original))
        XCTAssertEqual(info.linkCount, 2)
        XCTAssertEqual(info.reclaimableSize, 0)

        let size = try DirectorySizer.measure(temp.url.appendingPathComponent("dir"))
        XCTAssertEqual(size.fileCount, 1)
        XCTAssertEqual(size.logicalSize, 1_000_000)
    }

    func testSizerSkipsSymlinks() throws {
        try temp.file("dir/a.bin", bytes: 10_000)
        let big = try temp.file("outside/big.bin", bytes: 3_000_000)
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("dir/link"), withDestinationURL: big)
        let size = try DirectorySizer.measure(temp.url.appendingPathComponent("dir"))
        XCTAssertEqual(size.logicalSize, 10_000)
    }

    func testBundleIdentifierExtraction() {
        XCTAssertEqual(BundleIdentifier.extract(from: "com.example.App"), "com.example.App")
        XCTAssertEqual(BundleIdentifier.extract(from: "com.example.App.plist"), "com.example.App")
        XCTAssertEqual(BundleIdentifier.extract(from: "com.example.App.savedState"), "com.example.App")
        XCTAssertEqual(BundleIdentifier.extract(from: "ABCDE12345.com.example.shared"), "com.example.shared")
        XCTAssertEqual(BundleIdentifier.extract(from: "group.com.example.shared"), "com.example.shared")
        XCTAssertNil(BundleIdentifier.extract(from: "Google"))
        XCTAssertNil(BundleIdentifier.extract(from: "My Folder.v2"))
        XCTAssertTrue(BundleIdentifier.isApple("com.apple.Safari"))
    }
}
