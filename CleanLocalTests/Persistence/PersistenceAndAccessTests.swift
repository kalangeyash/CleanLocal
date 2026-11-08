import XCTest
@testable import CleanLocal

final class JSONFileStoreTests: XCTestCase {
    private var temp: TemporaryDirectory!

    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testRoundTripsMediaItems() async throws {
        let store = JSONFileStore<[MediaItem]>(fileURL: temp.url.appendingPathComponent("index.json"), defaultValue: [])
        let items = [makeItem(id: "a", contentHash: "abc", perceptualHash: .max, differenceHash: 42), makeItem(id: "p", photos: true)]
        try await store.save(items)
        let loaded = await store.load()
        XCTAssertEqual(loaded, items)
    }

    func testMissingFileReturnsDefault() async {
        let store = JSONFileStore<[String]>(fileURL: temp.url.appendingPathComponent("none.json"), defaultValue: ["default"])
        let value = await store.load()
        XCTAssertEqual(value, ["default"])
    }

    func testCorruptFileIsQuarantinedNotLost() async throws {
        let url = temp.url.appendingPathComponent("history.json")
        try Data("{ not json".utf8).write(to: url)
        let store = JSONFileStore<[DeletionRecord]>(fileURL: url, defaultValue: [])
        let value = await store.load()
        XCTAssertEqual(value, [])
        let siblings = try FileManager.default.contentsOfDirectory(atPath: temp.url.path)
        XCTAssertTrue(siblings.contains { $0.hasPrefix("history.corrupt-") }, "\(siblings)")
    }

    func testSchemaMismatchStartsFresh() async throws {
        let url = temp.url.appendingPathComponent("v.json")
        try await JSONFileStore<[String]>(fileURL: url, schemaVersion: 1, defaultValue: []).save(["old"])
        let value = await JSONFileStore<[String]>(fileURL: url, schemaVersion: 2, defaultValue: []).load()
        XCTAssertEqual(value, [])
    }

    func testResetRemovesFile() async throws {
        let url = temp.url.appendingPathComponent("r.json")
        let store = JSONFileStore<[String]>(fileURL: url, defaultValue: [])
        try await store.save(["x"])
        try await store.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPersistenceControllerUsesSeparateFiles() async throws {
        let controller = PersistenceController(baseURL: temp.url.appendingPathComponent("Support"))
        try await controller.locations.save([ScanLocation(displayName: "Pics", path: "/p", bookmarkData: Data([1, 2]))])
        try await controller.deletionHistory.save([])
        let locations = await controller.locations.load()
        XCTAssertEqual(locations.first?.displayName, "Pics")
        XCTAssertGreaterThan(controller.storageFootprint(), 0)
    }
}

final class BookmarkManagerTests: XCTestCase {
    private var temp: TemporaryDirectory!

    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testBookmarkRoundTrip() throws {
        let manager = BookmarkManager(usesSecurityScope: false)
        let folder = try temp.makeDirectory("Folder")
        let data = try manager.makeBookmark(for: folder)
        let resolution = try manager.resolve(data)
        XCTAssertEqual(resolution.url.resolvingSymlinksInPath().path, folder.resolvingSymlinksInPath().path)
        XCTAssertFalse(resolution.isStale)
    }

    func testBookmarkFollowsRenamedFolder() throws {
        let manager = BookmarkManager(usesSecurityScope: false)
        let folder = try temp.makeDirectory("Before")
        let data = try manager.makeBookmark(for: folder)
        let renamed = temp.url.appendingPathComponent("After")
        try FileManager.default.moveItem(at: folder, to: renamed)
        let resolution = try manager.resolve(data)
        XCTAssertEqual(resolution.url.lastPathComponent, "After")
    }

    func testSecurityScopedBookmarkInSandbox() throws {
        let manager = BookmarkManager(usesSecurityScope: true)
        let folder = try temp.makeDirectory("Scoped")
        let data: Data
        do {
            data = try manager.makeBookmark(for: folder)
        } catch {
            throw XCTSkip("Security-scoped bookmarks are unavailable in this test host: \(error)")
        }
        let resolution = try manager.resolve(data)
        let access = SecurityScopedAccess(url: resolution.url)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: resolution.url.path))
        access.stop()
        access.stop() // stopping twice must be harmless
    }

    func testInvalidBookmarkDataThrowsTypedError() {
        XCTAssertThrowsError(try BookmarkManager(usesSecurityScope: false).resolve(Data([0, 1, 2, 3]))) { error in
            guard case .bookmarkResolutionFailed = error as? CleanLocalError else {
                return XCTFail("Unexpected error \(error)")
            }
        }
    }

    @MainActor
    func testLocationAccessManagerActivatesAndDetectsRevokedAccess() throws {
        let bookmarks = BookmarkManager(usesSecurityScope: false)
        let folder = try temp.makeDirectory("Location")
        let location = ScanLocation(displayName: "Location", path: folder.path, bookmarkData: try bookmarks.makeBookmark(for: folder))
        let manager = LocationAccessManager(bookmarks: bookmarks)

        let activation = try manager.activate(location)
        XCTAssertEqual(activation.url.lastPathComponent, "Location")
        XCTAssertNotNil(manager.activeURL(for: location.id))

        manager.deactivate(location.id)
        try FileManager.default.removeItem(at: folder)
        XCTAssertThrowsError(try manager.activate(location))
        XCTAssertNil(manager.activeURL(for: location.id))
    }
}

final class StorageAnalyticsTests: XCTestCase {
    func testBreakdownSumsByCategory() {
        let items = [
            makeItem(format: .jpeg, size: 100), makeItem(format: .heic, size: 200),
            makeItem(format: .mov, size: 1_000), makeItem(format: .png, size: 50, isScreenshot: true),
            makeItem(format: .gif, size: 25),
        ]
        let breakdown = StorageAnalyticsService.breakdown(of: items)
        XCTAssertEqual(breakdown.totalBytes, 1_375)
        XCTAssertEqual(breakdown.totalCount, 5)
        XCTAssertEqual(breakdown.photoCount, 4)
        XCTAssertEqual(breakdown.videoCount, 1)
        XCTAssertEqual(breakdown.entry(for: .photos).bytes, 300)
        XCTAssertEqual(breakdown.entry(for: .videos).bytes, 1_000)
        XCTAssertEqual(breakdown.entry(for: .screenshots).count, 1)
        XCTAssertEqual(breakdown.entry(for: .other).bytes, 25)
        XCTAssertEqual(breakdown.entries.reduce(0) { $0 + $1.bytes }, breakdown.totalBytes)
    }

    func testReclaimableBytesCountsEachItemOnceAndExcludesKeepers() {
        let a = makeItem(id: "a", size: 100), b = makeItem(id: "b", size: 100), c = makeItem(id: "c", size: 100)
        let groups = [
            DuplicateGroup(id: "1", kind: .exact, items: [a, b], suggestedKeeperID: a.id, similarity: 1),
            DuplicateGroup(id: "2", kind: .exact, items: [a, b, c], suggestedKeeperID: a.id, similarity: 1),
        ]
        XCTAssertEqual(StorageAnalyticsService.reclaimableBytes(in: groups), 200)
        XCTAssertEqual(groups[1].reclaimableBytes, 200)
        XCTAssertEqual(groups[1].totalBytes, 300)
    }

    func testVolumeCapacityUsesRealFilesystemData() throws {
        let capacity = try XCTUnwrap(StorageAnalyticsService().startupVolume())
        XCTAssertGreaterThan(capacity.totalBytes, 0)
        XCTAssertLessThanOrEqual(capacity.availableBytes, capacity.totalBytes)
        XCTAssertEqual(capacity.usedBytes, capacity.totalBytes - capacity.availableBytes)
    }
}
