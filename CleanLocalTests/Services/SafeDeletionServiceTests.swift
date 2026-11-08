import XCTest
@testable import CleanLocal

/// Moves files into a private folder instead of the real Trash.
private final class FakeTrash: FileTrashing, @unchecked Sendable {
    let directory: URL
    var errorToThrow: Error?
    private(set) var trashed: [URL] = []

    init(directory: URL) { self.directory = directory }

    func trashItem(at url: URL) throws -> URL? {
        if let errorToThrow { throw errorToThrow }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        trashed.append(url)
        return destination
    }
}

private final class FakePhotosDeleter: PhotosAssetDeleting, @unchecked Sendable {
    var result: Result<Set<String>, Error> = .success([])
    private(set) var requested: [String] = []

    func deleteAssets(withLocalIdentifiers identifiers: [String]) async throws -> Set<String> {
        requested = identifiers
        return try result.get()
    }
}

final class SafeDeletionServiceTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var trash: FakeTrash!
    private let locationID = UUID()
    private var roots: [UUID: URL] { [locationID: temp.url.appendingPathComponent("media")] }

    override func setUpWithError() throws {
        temp = try TemporaryDirectory()
        try temp.makeDirectory("media")
        trash = FakeTrash(directory: temp.url.appendingPathComponent(".fake-trash"))
    }

    override func tearDown() { temp.cleanUp() }

    private func service(photos: PhotosAssetDeleting? = nil) -> SafeDeletionService {
        SafeDeletionService(trash: trash, photosDeleter: photos, policy: temp.policy)
    }

    /// Creates a real file and an index item that matches it exactly.
    private func indexedFile(_ relativePath: String, bytes: Int = 1_000) throws -> MediaItem {
        let url = try temp.writeData(Data(repeating: 1, count: bytes), to: relativePath)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return makeItem(path: url.path, size: Int64(bytes), modified: attributes[.modificationDate] as? Date, locationID: locationID)
    }

    func testMovesValidatedFilesToTrashAndReportsReclaimedBytes() async throws {
        let a = try indexedFile("media/a.jpg", bytes: 1_000)
        let b = try indexedFile("media/sub/b.jpg", bytes: 2_500)
        let report = await service().remove([a, b], authorizedRoots: roots)
        XCTAssertEqual(report.successes.count, 2)
        XCTAssertEqual(report.reclaimedBytes, 3_500)
        XCTAssertEqual(report.succeededItemIDs, [a.id, b.id])
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(a.path)))
        XCTAssertTrue(report.records.allSatisfy { $0.status == .movedToTrash && $0.trashedPath != nil })
    }

    func testRefusesProtectedLocations() async throws {
        let item = try indexedFile("media/protected/a.jpg")
        let protectedPolicy = ProtectedPathPolicy(protectedPrefixes: [temp.url.appendingPathComponent("media/protected").path])
        let report = await SafeDeletionService(trash: trash, photosDeleter: nil, policy: protectedPolicy).remove([item], authorizedRoots: roots)
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertTrue(trash.trashed.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(item.path)))
    }

    func testRefusesFilesOutsideAuthorizedLocations() async throws {
        let outside = try indexedFile("elsewhere/a.jpg")
        let report = await service().remove([outside], authorizedRoots: roots)
        XCTAssertEqual(report.failures.first?.errorDescription, CleanLocalError.outsideAuthorizedLocations(path: outside.path ?? "").errorDescription)

        let unknownLocation = makeItem(path: try XCTUnwrap(outside.path), size: outside.size, modified: outside.modificationDate, locationID: UUID())
        let second = await service().remove([unknownLocation], authorizedRoots: roots)
        XCTAssertEqual(second.failures.count, 1)
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testRefusesSymbolicLinksAndSymlinkedParentEscapes() async throws {
        let target = try indexedFile("elsewhere/target.jpg")
        let linkURL = temp.url.appendingPathComponent("media/link.jpg")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: try XCTUnwrap(target.url))
        let link = makeItem(path: linkURL.path, size: target.size, modified: target.modificationDate, locationID: locationID)

        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("media/escape"),
                                                   withDestinationURL: temp.url.appendingPathComponent("elsewhere"))
        let escaped = makeItem(path: temp.url.appendingPathComponent("media/escape/target.jpg").path,
                               size: target.size, modified: target.modificationDate, locationID: locationID)

        let report = await service().remove([link, escaped], authorizedRoots: roots)
        XCTAssertEqual(report.failures.count, 2)
        XCTAssertEqual(report.failures.first?.errorDescription, CleanLocalError.symbolicLinkRefused(path: linkURL.path).errorDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(target.path)), "the link target must survive")
    }

    func testRefusesFilesThatChangedSinceScan() async throws {
        var item = try indexedFile("media/a.jpg", bytes: 100)
        item.size = 99
        let report = await service().remove([item], authorizedRoots: roots)
        XCTAssertEqual(report.failures.first?.errorDescription, CleanLocalError.fileChangedSinceScan(path: item.path ?? "").errorDescription)
    }

    func testMissingFileIsReportedAsFailure() async throws {
        let item = try indexedFile("media/a.jpg")
        try FileManager.default.removeItem(atPath: try XCTUnwrap(item.path))
        let report = await service().remove([item], authorizedRoots: roots)
        XCTAssertEqual(report.failures.first?.errorDescription, CleanLocalError.fileNotFound(path: item.path ?? "").errorDescription)
        XCTAssertEqual(report.reclaimedBytes, 0, "never claim space for failed operations")
    }

    func testDisconnectedVolumeIsReported() async throws {
        let item = try indexedFile("media/a.jpg")
        let missingRoot = [locationID: temp.url.appendingPathComponent("unplugged-drive")]
        let movedItem = makeItem(path: missingRoot[locationID]!.appendingPathComponent("a.jpg").path, size: item.size,
                                 modified: item.modificationDate, locationID: locationID)
        let report = await service().remove([movedItem], authorizedRoots: missingRoot)
        XCTAssertEqual(report.failures.first?.errorDescription, CleanLocalError.volumeUnavailable(path: movedItem.path ?? "").errorDescription)
    }

    func testLockedFileIsRefused() async throws {
        let item = try indexedFile("media/locked.jpg")
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: try XCTUnwrap(item.path))
        let report = await service().remove([item], authorizedRoots: roots)
        XCTAssertEqual(report.failures.first?.errorDescription, CleanLocalError.fileLocked(path: item.path ?? "").errorDescription)
    }

    func testPartialFailureKeepsSuccessfulResults() async throws {
        let good = try indexedFile("media/good.jpg", bytes: 500)
        let missing = try indexedFile("media/missing.jpg", bytes: 700)
        try FileManager.default.removeItem(atPath: try XCTUnwrap(missing.path))
        let report = await service().remove([good, missing], authorizedRoots: roots)
        XCTAssertEqual(report.successes.map(\.itemID), [good.id])
        XCTAssertEqual(report.failures.map(\.itemID), [missing.id])
        XCTAssertEqual(report.reclaimedBytes, 500)
    }

    func testTrashErrorsAreMappedPrecisely() async throws {
        let item = try indexedFile("media/a.jpg")
        trash.errorToThrow = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
        let report = await service().remove([item], authorizedRoots: roots)
        XCTAssertEqual(report.failures.first?.errorDescription, CleanLocalError.permissionDenied(path: item.path ?? "").errorDescription)

        let busy = NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EBUSY))])
        XCTAssertEqual(SafeDeletionService.map(busy, path: "/p"), .fileInUse(path: "/p"))
        XCTAssertEqual(SafeDeletionService.map(NSError(domain: NSCocoaErrorDomain, code: NSFileWriteVolumeReadOnlyError), path: "/p"), .readOnlyVolume(path: "/p"))
    }

    func testPhotosAssetsUsePhotoKitDeleterNotTheFilesystem() async throws {
        let deleter = FakePhotosDeleter()
        deleter.result = .success(["asset-1"])
        let deleted = makeItem(id: "asset-1", photos: true)
        let gone = makeItem(id: "asset-2", photos: true)
        let report = await service(photos: deleter).remove([deleted, gone], authorizedRoots: [:])
        XCTAssertEqual(deleter.requested.sorted(), ["asset-1", "asset-2"])
        XCTAssertEqual(report.successes.map(\.status), [.removedFromPhotos])
        XCTAssertEqual(report.failures.map(\.itemID), [gone.id])
        XCTAssertTrue(trash.trashed.isEmpty)
    }

    func testCancelledPhotosDeletionRecordsFailure() async throws {
        let deleter = FakePhotosDeleter()
        deleter.result = .failure(CleanLocalError.photosDeletionCancelled)
        let report = await service(photos: deleter).remove([makeItem(id: "a", photos: true)], authorizedRoots: [:])
        XCTAssertEqual(report.failures.first?.errorDescription, CleanLocalError.photosDeletionCancelled.errorDescription)
        XCTAssertEqual(report.reclaimedBytes, 0)
    }
}
