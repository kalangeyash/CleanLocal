import XCTest
@testable import CleanLocal

/// Fake Trash that moves files into a private folder (never the user's real Trash).
private final class FolderTrash: FileTrashing, @unchecked Sendable {
    let directory: URL
    init(directory: URL) { self.directory = directory }

    func trashItem(at url: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
}

/// Full flow: add folder → scan → find duplicates → confirm deletion → index, analysis,
/// history and persistence all update consistently.
@MainActor
final class StoreIntegrationTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        temp = try TemporaryDirectory()
        suiteName = "CleanLocalTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        temp.cleanUp()
    }

    private struct Stack {
        let settings: SettingsStore
        let library: LibraryStore
        let analysis: AnalysisStore
        let deletion: DeletionStore
        let persistence: PersistenceController
    }

    private func makeStack() -> Stack {
        let persistence = PersistenceController(baseURL: temp.url.appendingPathComponent("Support"))
        let settings = SettingsStore(defaults: defaults)
        settings.includePhotosLibrary = false
        let photos = PhotosLibraryService()
        let library = LibraryStore(
            persistence: persistence, scanner: MediaScannerService(), bookmarks: BookmarkManager(usesSecurityScope: false),
            photos: photos, settings: settings, policy: temp.policy
        )
        let analysis = AnalysisStore(library: library, settings: settings,
                                     duplicateService: DuplicateDetectionService(), similarityService: SimilarityDetectionService())
        let deletion = DeletionStore(
            service: SafeDeletionService(trash: FolderTrash(directory: temp.url.appendingPathComponent(".trash")), photosDeleter: nil, policy: temp.policy),
            library: library, analysis: analysis, persistence: persistence
        )
        return Stack(settings: settings, library: library, analysis: analysis, deletion: deletion, persistence: persistence)
    }

    func testScanAnalyzeDeleteFlow() async throws {
        let media = try temp.makeDirectory("Media")
        let image = TestMedia.makeImage(width: 200, height: 150, pattern: .gradientWithDisc)
        try TestMedia.writeImage(image, to: media.appendingPathComponent("Originals/photo.png"))
        try FileManager.default.copyItem(at: media.appendingPathComponent("Originals/photo.png"),
                                         to: media.appendingPathComponent("photo copy.png"))
        try TestMedia.writeImage(TestMedia.makeImage(width: 90, height: 90, pattern: .stripes),
                                 to: media.appendingPathComponent("unique.png"))

        let stack = makeStack()
        await stack.library.bootstrap()
        try stack.library.addLocation(media)
        XCTAssertEqual(stack.library.locations.count, 1)
        XCTAssertEqual(stack.library.locationStatuses.values.first, .available)

        // Scan
        await stack.library.startScan()?.value
        XCTAssertEqual(stack.library.items.count, 3)
        XCTAssertEqual(stack.library.breakdown.totalCount, 3)
        XCTAssertFalse(stack.library.isScanning)
        XCTAssertEqual(stack.library.scanSessions.first?.mediaCount, 3)

        // Duplicates
        await stack.analysis.analyzeDuplicates()?.value
        XCTAssertEqual(stack.analysis.duplicateGroups.count, 1)
        XCTAssertEqual(stack.analysis.redundantCopyCount, 1)
        let group = try XCTUnwrap(stack.analysis.duplicateGroups.first)
        XCTAssertEqual(group.keeper?.filename, "photo.png", "the copy-named file is not suggested as keeper")
        XCTAssertTrue(stack.library.items.filter { group.items.map(\.id).contains($0.id) }.allSatisfy { $0.contentHash != nil },
                      "hashes are cached back into the index")

        // Delete the suggested selection
        let selection = DuplicateSelectionPolicy.autoSelection(for: stack.analysis.duplicateGroups)
        let toDelete = stack.library.items.filter { selection.contains($0.id) }
        stack.deletion.requestDeletion(of: toDelete)
        let session = try XCTUnwrap(stack.deletion.session)
        XCTAssertEqual(session.fullySelectedGroupCount, 0)
        XCTAssertEqual(session.items.map(\.filename), ["photo copy.png"])

        await stack.deletion.confirm()
        guard case let .finished(report)? = stack.deletion.session?.phase else { return XCTFail("Expected a finished session") }
        XCTAssertEqual(report.successes.count, 1)
        XCTAssertEqual(stack.library.items.count, 2)
        XCTAssertTrue(stack.analysis.duplicateGroups.isEmpty, "a group with one remaining copy is no longer a duplicate group")
        XCTAssertEqual(stack.deletion.history.count, 1)
        XCTAssertEqual(stack.deletion.totalReclaimedBytes, toDelete.first?.size)
        XCTAssertTrue(FileManager.default.fileExists(atPath: media.appendingPathComponent("Originals/photo.png").path))
        stack.deletion.dismiss()
        XCTAssertNil(stack.deletion.session)

        // Persistence: a fresh stack sees the same state.
        try await Task.sleep(for: .milliseconds(300)) // saves are fire-and-forget
        let reloaded = makeStack()
        await reloaded.library.bootstrap()
        await reloaded.deletion.bootstrap()
        XCTAssertEqual(reloaded.library.locations.count, 1)
        XCTAssertEqual(Set(reloaded.library.items.map(\.filename)), ["photo.png", "unique.png"])
        XCTAssertEqual(reloaded.deletion.history.count, 1)
    }

    func testRescanAfterExternalChangesIsIncrementalAndPrunesRemovedFiles() async throws {
        let media = try temp.makeDirectory("Media")
        try TestMedia.writeImage(TestMedia.makeImage(width: 40, height: 40, pattern: .stripes), to: media.appendingPathComponent("a.png"))
        try TestMedia.writeImage(TestMedia.makeImage(width: 40, height: 40, pattern: .gradientWithDisc), to: media.appendingPathComponent("b.png"))

        let stack = makeStack()
        await stack.library.bootstrap()
        try stack.library.addLocation(media)
        await stack.library.startScan()?.value
        XCTAssertEqual(stack.library.items.count, 2)
        let firstDiscovery = try XCTUnwrap(stack.library.items.first { $0.filename == "a.png" }?.discoveredAt)

        try FileManager.default.removeItem(at: media.appendingPathComponent("b.png"))
        await stack.library.startScan()?.value
        XCTAssertEqual(stack.library.items.map(\.filename), ["a.png"])
        XCTAssertEqual(stack.library.items.first?.discoveredAt, firstDiscovery, "unchanged files keep their identity")
        XCTAssertEqual(stack.library.scanSessions.first?.removedItemCount, 1)
    }

    func testProtectedAndDuplicateLocationsAreRejected() async throws {
        let stack = makeStack()
        await stack.library.bootstrap()
        let media = try temp.makeDirectory("Media")
        try stack.library.addLocation(media)
        XCTAssertThrowsError(try stack.library.addLocation(media)) { error in
            guard case .locationAlreadyAdded = error as? CleanLocalError else { return XCTFail("\(error)") }
        }
        let protected = try temp.makeDirectory("protected/inner")
        XCTAssertThrowsError(try stack.library.addLocation(protected)) { error in
            guard case .protectedLocation = error as? CleanLocalError else { return XCTFail("\(error)") }
        }
    }

    func testRemovingLocationDropsItsItemsButNeverTouchesFiles() async throws {
        let media = try temp.makeDirectory("Media")
        let file = try TestMedia.writeImage(TestMedia.makeImage(width: 20, height: 20, pattern: .stripes), to: media.appendingPathComponent("a.png"))
        let stack = makeStack()
        await stack.library.bootstrap()
        try stack.library.addLocation(media)
        await stack.library.startScan()?.value
        XCTAssertEqual(stack.library.items.count, 1)

        stack.library.removeLocation(try XCTUnwrap(stack.library.locations.first?.id))
        XCTAssertTrue(stack.library.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testCancellingDeletionLeavesEverythingUntouched() async throws {
        let media = try temp.makeDirectory("Media")
        try TestMedia.writeImage(TestMedia.makeImage(width: 20, height: 20, pattern: .stripes), to: media.appendingPathComponent("a.png"))
        let stack = makeStack()
        await stack.library.bootstrap()
        try stack.library.addLocation(media)
        await stack.library.startScan()?.value

        stack.deletion.requestDeletion(of: stack.library.items)
        XCTAssertNotNil(stack.deletion.session)
        stack.deletion.dismiss()
        XCTAssertNil(stack.deletion.session)
        XCTAssertEqual(stack.library.items.count, 1)
        XCTAssertTrue(stack.deletion.history.isEmpty)
    }

    func testFullySelectedDuplicateGroupsAreFlaggedBeforeDeletion() async throws {
        let media = try temp.makeDirectory("Media")
        let data = Data(repeating: 7, count: 4_096)
        try temp.writeData(data, to: "Media/one.jpg")
        try temp.writeData(data, to: "Media/two.jpg")
        let stack = makeStack()
        await stack.library.bootstrap()
        try stack.library.addLocation(media)
        await stack.library.startScan()?.value
        await stack.analysis.analyzeDuplicates()?.value
        XCTAssertEqual(stack.analysis.duplicateGroups.count, 1)

        stack.deletion.requestDeletion(of: stack.library.items)
        XCTAssertEqual(stack.deletion.session?.fullySelectedGroupCount, 1)
    }
}

@MainActor
final class SettingsStoreTests: XCTestCase {
    func testSettingsPersistAcrossInstances() throws {
        let suite = "CleanLocalSettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = SettingsStore(defaults: defaults)
        XCTAssertEqual(first.largeFileThresholdMB, AppConstants.Defaults.largeFileThresholdMB)
        XCTAssertEqual(first.enabledFormats, Set(MediaFormat.allCases))
        first.largeFileThresholdMB = 500
        first.similarityThreshold = 0.95
        first.oldMediaThreshold = .fiveYears
        first.enabledFormats = [.jpeg, .mov]
        first.includeHiddenFiles = true

        let second = SettingsStore(defaults: defaults)
        XCTAssertEqual(second.largeFileThresholdMB, 500)
        XCTAssertEqual(second.similarityThreshold, 0.95)
        XCTAssertEqual(second.oldMediaThreshold, .fiveYears)
        XCTAssertEqual(second.enabledFormats, [.jpeg, .mov])
        XCTAssertTrue(second.scanConfiguration.includeHiddenFiles)
        XCTAssertNil(second.scanConfiguration.classifier.format(forExtension: "png"))

        second.resetToDefaults()
        XCTAssertEqual(SettingsStore(defaults: defaults).largeFileThresholdMB, AppConstants.Defaults.largeFileThresholdMB)
    }

    func testOldMediaCutoffs() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let calendar = Calendar.current
        XCTAssertEqual(OldMediaThreshold.oneYear.cutoff(from: now), calendar.date(byAdding: .year, value: -1, to: now))
        XCTAssertLessThan(OldMediaThreshold.fiveYears.cutoff(from: now), OldMediaThreshold.twoYears.cutoff(from: now))
    }
}
