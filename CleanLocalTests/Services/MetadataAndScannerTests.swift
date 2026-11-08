import ImageIO
import XCTest
@testable import CleanLocal

final class MediaMetadataServiceTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private let service = MediaMetadataService()

    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testReadsImageDimensions() async throws {
        let url = try TestMedia.writeImage(TestMedia.makeImage(width: 320, height: 200, pattern: .stripes),
                                           to: temp.url.appendingPathComponent("a.png"))
        let metadata = await service.metadata(for: url, kind: .image)
        XCTAssertEqual(metadata.pixelWidth, 320)
        XCTAssertEqual(metadata.pixelHeight, 200)
        XCTAssertNil(metadata.duration)
    }

    func testReadsExifCaptureDateUserCommentAndOrientation() async throws {
        let url = try TestMedia.writeImage(
            TestMedia.makeImage(width: 300, height: 100, pattern: .gradientWithDisc),
            to: temp.url.appendingPathComponent("b.jpg"), type: .jpeg,
            properties: [
                kCGImagePropertyOrientation: 6,
                kCGImagePropertyExifDictionary: [
                    kCGImagePropertyExifDateTimeOriginal: "2019:07:04 18:30:05",
                    kCGImagePropertyExifUserComment: "Screenshot",
                ] as CFDictionary,
            ]
        )
        let metadata = await service.metadata(for: url, kind: .image)
        XCTAssertEqual(metadata.pixelWidth, 100, "orientation 6 is rotated, so dimensions swap")
        XCTAssertEqual(metadata.pixelHeight, 300)
        XCTAssertEqual(metadata.exifUserComment, "Screenshot")
        let components = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day, .hour], from: try XCTUnwrap(metadata.captureDate))
        XCTAssertEqual(components.year, 2019)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 4)
        XCTAssertEqual(components.hour, 18)
    }

    func testUnreadableFilesYieldEmptyMetadataInsteadOfFailing() async throws {
        let image = try temp.writeData(Data("not an image".utf8), to: "fake.jpg")
        let video = try temp.writeData(Data("not a video".utf8), to: "fake.mkv")
        let imageMetadata = await service.metadata(for: image, kind: .image)
        let videoMetadata = await service.metadata(for: video, kind: .video)
        XCTAssertEqual(imageMetadata, MediaMetadata())
        XCTAssertNil(videoMetadata.duration)
    }

    func testParsesExifDates() {
        XCTAssertNotNil(MediaMetadataService.parseExifDate("2021:12:31 23:59:59"))
        XCTAssertNil(MediaMetadataService.parseExifDate("0000:00:00 00:00:00"))
        XCTAssertNil(MediaMetadataService.parseExifDate("garbage"))
    }
}

final class MediaScannerServiceTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private let locationID = UUID()

    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    private var configuration: ScanConfiguration {
        ScanConfiguration(classifier: MediaTypeClassifier(), includeHiddenFiles: false, policy: temp.policy, metadataConcurrency: 4)
    }

    private var root: ScanRoot { ScanRoot(locationID: locationID, name: "Test", url: temp.url) }

    private func buildFixtureTree() throws {
        let png = TestMedia.makeImage(width: 64, height: 48, pattern: .stripes)
        try TestMedia.writeImage(png, to: temp.url.appendingPathComponent("a.png"))
        try TestMedia.writeImage(png, to: temp.url.appendingPathComponent("nested/deeper/b.png"))
        try TestMedia.writeImage(png, to: temp.url.appendingPathComponent("Screenshot 2024-01-01 at 10.00.00.png"))
        try temp.writeData(Data(repeating: 0, count: 2048), to: "nested/clip.mov")
        try temp.writeData(Data("notes".utf8), to: "notes.txt")
        // Hidden file, package contents and protected folder must be skipped.
        try TestMedia.writeImage(png, to: temp.url.appendingPathComponent(".hidden.png"))
        try TestMedia.writeImage(png, to: temp.url.appendingPathComponent("Tool.app/Contents/Resources/icon.png"))
        try TestMedia.writeImage(png, to: temp.url.appendingPathComponent("Library.photoslibrary/originals/c.png"))
        try TestMedia.writeImage(png, to: temp.url.appendingPathComponent("protected/secret.png"))
        // Symbolic links: one to a file, one creating a directory loop.
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("link.png"),
                                                   withDestinationURL: temp.url.appendingPathComponent("a.png"))
        try FileManager.default.createSymbolicLink(at: temp.url.appendingPathComponent("nested/loop"),
                                                   withDestinationURL: temp.url)
    }

    func testDiscoversOnlyAuthorizedRealMediaFiles() async throws {
        try buildFixtureTree()
        let result = try await MediaScannerService().scan(roots: [root], previousItems: [:], configuration: configuration) { _ in }
        let names = Set(result.items.map(\.filename))
        XCTAssertEqual(names, ["a.png", "b.png", "Screenshot 2024-01-01 at 10.00.00.png", "clip.mov"])
        XCTAssertEqual(result.newItemCount, 4)

        let screenshot = try XCTUnwrap(result.items.first { $0.filename.hasPrefix("Screenshot") })
        XCTAssertTrue(screenshot.isScreenshot)
        let png = try XCTUnwrap(result.items.first { $0.filename == "a.png" })
        XCTAssertEqual(png.pixelWidth, 64)
        XCTAssertEqual(png.source, .fileSystem(locationID: locationID))
        XCTAssertEqual(result.items.first { $0.filename == "clip.mov" }?.kind, .video)
    }

    func testIncludesHiddenFilesWhenEnabled() async throws {
        try buildFixtureTree()
        var config = configuration
        config.includeHiddenFiles = true
        let result = try await MediaScannerService().scan(roots: [root], previousItems: [:], configuration: config) { _ in }
        XCTAssertTrue(result.items.contains { $0.filename == ".hidden.png" })
        XCTAssertFalse(result.items.contains { $0.filename == "icon.png" || $0.filename == "secret.png" })
    }

    func testIncrementalRescanReusesUnchangedFilesAndDetectsChanges() async throws {
        try buildFixtureTree()
        let scanner = MediaScannerService()
        let first = try await scanner.scan(roots: [root], previousItems: [:], configuration: configuration) { _ in }

        // Pretend hashes were computed after the first scan.
        var index = Dictionary(uniqueKeysWithValues: first.items.map { ($0.id, $0) })
        for key in index.keys { index[key]?.contentHash = "cached" }

        // Modify one file, delete another, add a new one.
        let changed = temp.url.appendingPathComponent("a.png")
        try TestMedia.writeImage(TestMedia.makeImage(width: 80, height: 80, pattern: .checkerboard(cell: 8)), to: changed)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: changed.path)
        try FileManager.default.removeItem(at: temp.url.appendingPathComponent("nested/clip.mov"))
        try TestMedia.writeImage(TestMedia.makeImage(width: 10, height: 10, pattern: .stripes), to: temp.url.appendingPathComponent("new.png"))

        let second = try await scanner.scan(roots: [root], previousItems: index, configuration: configuration) { _ in }
        XCTAssertEqual(second.reusedItemCount, 2)
        XCTAssertEqual(second.newItemCount, 1)
        XCTAssertEqual(second.removedItemIDs, [temp.url.appendingPathComponent("nested/clip.mov").path])

        let reread = try XCTUnwrap(second.items.first { $0.filename == "a.png" })
        XCTAssertNil(reread.contentHash, "a changed file must not keep a stale hash")
        XCTAssertEqual(reread.pixelWidth, 80)
        XCTAssertEqual(second.items.first { $0.filename == "b.png" }?.contentHash, "cached")
    }

    func testUnreadableFolderIsReportedAndScanContinues() async throws {
        try buildFixtureTree()
        let locked = try temp.makeDirectory("locked")
        try TestMedia.writeImage(TestMedia.makeImage(width: 8, height: 8, pattern: .stripes), to: locked.appendingPathComponent("x.png"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

        let result = try await MediaScannerService().scan(roots: [root], previousItems: [:], configuration: configuration) { _ in }
        XCTAssertEqual(result.items.count, 4)
        XCTAssertTrue(result.issues.contains { $0.path.hasSuffix("locked") || $0.path.contains("/locked/") })
    }

    func testProtectedRootIsRefused() async throws {
        let protected = try temp.makeDirectory("protected")
        try TestMedia.writeImage(TestMedia.makeImage(width: 8, height: 8, pattern: .stripes), to: protected.appendingPathComponent("x.png"))
        let result = try await MediaScannerService().scan(
            roots: [ScanRoot(locationID: locationID, name: "Protected", url: protected)],
            previousItems: [:], configuration: configuration
        ) { _ in }
        XCTAssertTrue(result.items.isEmpty)
        XCTAssertEqual(result.issues.count, 1)
    }

    func testOverlappingRootsDoNotDuplicateItems() async throws {
        try buildFixtureTree()
        let nested = ScanRoot(locationID: UUID(), name: "Nested", url: temp.url.appendingPathComponent("nested"))
        let result = try await MediaScannerService().scan(roots: [root, nested], previousItems: [:], configuration: configuration) { _ in }
        XCTAssertEqual(result.items.count, Set(result.items.map(\.id)).count)
        XCTAssertEqual(result.items.count, 4)
    }

    func testCancellationStopsTheScan() async throws {
        let data = Data(repeating: 1, count: 16)
        for index in 0..<3000 { try temp.writeData(data, to: "bulk/\(index / 100)/file\(index).jpg") }

        let scanner = MediaScannerService()
        let configuration = self.configuration
        let root = self.root
        let task = Task { try await scanner.scan(roots: [root], previousItems: [:], configuration: configuration) { _ in } }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected the scan to be cancelled")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        // The scanner is reusable after cancellation.
        let result = try await scanner.scan(roots: [root], previousItems: [:], configuration: configuration) { _ in }
        XCTAssertEqual(result.items.count, 3000)
    }

    func testReportsProgress() async throws {
        try buildFixtureTree()
        let recorder = ProgressRecorder<ScanProgress>()
        _ = try await MediaScannerService().scan(roots: [root], previousItems: [:], configuration: configuration) { recorder.record($0) }
        let phases = Set(recorder.values.map(\.phase))
        XCTAssertTrue(phases.contains(.discovering))
        XCTAssertTrue(phases.contains(.readingMetadata))
        XCTAssertEqual(recorder.values.last?.phase, .finalizing)
    }
}
