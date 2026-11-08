import XCTest
@testable import CleanLocal

final class DuplicateDetectionServiceTests: XCTestCase {
    private var temp: TemporaryDirectory!
    private let locationID = UUID()

    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    private func fileItem(_ relativePath: String, data: Data, created: Date = .now) throws -> MediaItem {
        let url = try temp.writeData(data, to: relativePath)
        return makeItem(path: url.path, format: .jpeg, size: Int64(data.count), created: created,
                        width: nil, height: nil, locationID: locationID)
    }

    func testFindsExactDuplicatesAndIgnoresLookalikes() async throws {
        let content = Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        var sameSizeDifferentMiddle = content
        sameSizeDifferentMiddle[100_000] &+= 1

        let original = try fileItem("Pictures/photo.jpg", data: content, created: Date(timeIntervalSince1970: 1_000))
        let copy = try fileItem("Downloads/photo (1).jpg", data: content, created: Date(timeIntervalSince1970: 2_000))
        let lookalike = try fileItem("Pictures/other.jpg", data: sameSizeDifferentMiddle)
        let unique = try fileItem("Pictures/unique.jpg", data: Data(repeating: 3, count: 5_000))

        let result = try await DuplicateDetectionService().findExactDuplicates(in: [original, copy, lookalike, unique])
        XCTAssertEqual(result.groups.count, 1)
        let group = try XCTUnwrap(result.groups.first)
        XCTAssertEqual(Set(group.items.map(\.id)), [original.id, copy.id])
        XCTAssertEqual(group.kind, .exact)
        XCTAssertEqual(group.suggestedKeeperID, original.id, "the copy in Downloads named '(1)' should not be the keeper")
        XCTAssertEqual(group.reclaimableBytes, Int64(content.count))
        XCTAssertNil(result.computedHashes[unique.id], "unique sizes are never hashed")
    }

    func testReusesCachedHashesWithoutReadingFiles() async throws {
        // Paths do not exist: if the service tried to read them, the items would be dropped.
        let a = makeItem(path: "/nonexistent/a.jpg", size: 10, contentHash: "same")
        let b = makeItem(path: "/nonexistent/b.jpg", size: 10, contentHash: "same")
        let result = try await DuplicateDetectionService().findExactDuplicates(in: [a, b])
        XCTAssertEqual(result.groups.count, 1)
        XCTAssertTrue(result.computedHashes.isEmpty)
    }

    func testDifferentDimensionsAreNeverGrouped() async throws {
        let a = makeItem(path: "/x/a.jpg", size: 10, width: 100, height: 100, contentHash: "h")
        let b = makeItem(path: "/x/b.jpg", size: 10, width: 200, height: 50, contentHash: "h")
        let result = try await DuplicateDetectionService().findExactDuplicates(in: [a, b])
        XCTAssertTrue(result.groups.isEmpty)
    }

    func testUnreadableFilesAreSkippedNotFatal() async throws {
        let content = Data(repeating: 9, count: 4_096)
        let a = try fileItem("a.jpg", data: content)
        let b = try fileItem("b.jpg", data: content)
        let ghost = makeItem(path: temp.url.appendingPathComponent("ghost.jpg").path, size: 4_096, width: nil, height: nil)
        let result = try await DuplicateDetectionService().findExactDuplicates(in: [a, b, ghost])
        XCTAssertEqual(result.groups.first?.items.count, 2)
    }

    func testReportsProgressUpToCompletion() async throws {
        let content = Data(repeating: 5, count: 1_024)
        let items = try (0..<4).map { try fileItem("dup\($0).jpg", data: content) }
        let recorder = ProgressRecorder<Double>()
        _ = try await DuplicateDetectionService().findExactDuplicates(in: items) { recorder.record($0) }
        XCTAssertEqual(recorder.values.last, 1)
    }
}

final class DuplicateSelectionPolicyTests: XCTestCase {
    func testAutoSelectionNeverSelectsKeeperOrSingletons() {
        let a = makeItem(id: "a"), b = makeItem(id: "b"), c = makeItem(id: "c"), solo = makeItem(id: "solo")
        let groups = [
            DuplicateGroup(id: "1", kind: .exact, items: [a, b, c], suggestedKeeperID: a.id, similarity: 1),
            DuplicateGroup(id: "2", kind: .exact, items: [solo], suggestedKeeperID: solo.id, similarity: 1),
        ]
        let selection = DuplicateSelectionPolicy.autoSelection(for: groups)
        XCTAssertEqual(selection, [b.id, c.id])
        for group in groups {
            XCTAssertFalse(group.items.allSatisfy { selection.contains($0.id) }, "every group keeps at least one copy")
        }
    }

    func testDetectsFullySelectedGroups() {
        let a = makeItem(id: "a"), b = makeItem(id: "b")
        let group = DuplicateGroup(id: "g", kind: .exact, items: [a, b], suggestedKeeperID: a.id, similarity: 1)
        XCTAssertTrue(DuplicateSelectionPolicy.groupsFullySelected(by: [b.id], in: [group]).isEmpty)
        XCTAssertEqual(DuplicateSelectionPolicy.groupsFullySelected(by: [a.id, b.id], in: [group]).map(\.id), ["g"])
    }

    func testKeeperPrefersOrganizedOriginals() {
        let download = makeItem(path: "/Users/me/Downloads/IMG_1.jpg", created: Date(timeIntervalSince1970: 0))
        let pictures = makeItem(path: "/Users/me/Pictures/IMG_1.jpg", created: Date(timeIntervalSince1970: 100))
        let copy = makeItem(path: "/Users/me/Pictures/IMG_1 copy.jpg", created: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(DuplicateSelectionPolicy.suggestedKeeper(forExactDuplicates: [download, copy, pictures]), pictures.id)
    }

    func testSimilarKeeperPrefersHighestResolution() {
        let small = makeItem(id: "small", size: 9_000, width: 800, height: 600)
        let large = makeItem(id: "large", size: 5_000, width: 4000, height: 3000)
        XCTAssertEqual(DuplicateSelectionPolicy.suggestedKeeper(forSimilar: [small, large]), large.id)
    }

    func testCopyNameHeuristic() {
        XCTAssertTrue(DuplicateSelectionPolicy.looksLikeCopy("IMG_0001 copy.jpg"))
        XCTAssertTrue(DuplicateSelectionPolicy.looksLikeCopy("IMG_0001 (2).jpg"))
        XCTAssertFalse(DuplicateSelectionPolicy.looksLikeCopy("Holiday (Paris).jpg"))
        XCTAssertFalse(DuplicateSelectionPolicy.looksLikeCopy("IMG_0001.jpg"))
    }
}

final class SimilarityDetectionTests: XCTestCase {
    private var temp: TemporaryDirectory!

    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testGroupsByHammingDistance() throws {
        let base: UInt64 = 0xF0F0_F0F0_0F0F_0F0F
        let near = base ^ 0b111 // 3 bits away
        let far = ~base
        let items = [
            makeItem(id: "a", contentHash: "1", perceptualHash: base, differenceHash: base),
            makeItem(id: "b", contentHash: "2", perceptualHash: near, differenceHash: near),
            makeItem(id: "c", contentHash: "3", perceptualHash: far, differenceHash: far),
        ]
        let groups = try SimilarityDetectionService.groupSimilar(items, maxDistance: 6)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].items.map(\.filename)), ["a.jpg", "b.jpg"])
        XCTAssertEqual(groups[0].kind, .similar)
        XCTAssertEqual(groups[0].similarity, 1 - 3.0 / 64, accuracy: 0.0001)

        XCTAssertTrue(try SimilarityDetectionService.groupSimilar(items, maxDistance: 2).isEmpty)
    }

    func testExcludesExactDuplicateSetsAndLowInformationImages() throws {
        let hash: UInt64 = 0xAAAA_5555_AAAA_5555
        let exactPair = [
            makeItem(id: "a", contentHash: "same", perceptualHash: hash, differenceHash: hash),
            makeItem(id: "b", contentHash: "same", perceptualHash: hash, differenceHash: hash),
        ]
        XCTAssertTrue(try SimilarityDetectionService.groupSimilar(exactPair, maxDistance: 6).isEmpty)

        let blank = [
            makeItem(id: "c", perceptualHash: 0, differenceHash: 0),
            makeItem(id: "d", perceptualHash: 0, differenceHash: 0),
        ]
        XCTAssertTrue(try SimilarityDetectionService.groupSimilar(blank, maxDistance: 6).isEmpty)
    }

    func testIncompatibleAspectRatiosAreNotGrouped() throws {
        let hash: UInt64 = 0xAAAA_5555_AAAA_5555
        let items = [
            makeItem(id: "wide", width: 4000, height: 1000, perceptualHash: hash, differenceHash: hash),
            makeItem(id: "square", width: 1000, height: 1000, perceptualHash: hash, differenceHash: hash),
        ]
        XCTAssertTrue(try SimilarityDetectionService.groupSimilar(items, maxDistance: 6).isEmpty)
    }

    func testEndToEndWithGeneratedImages() async throws {
        let original = TestMedia.makeImage(width: 1200, height: 900, pattern: .gradientWithDisc)
        let originalURL = try TestMedia.writeImage(original, to: temp.url.appendingPathComponent("original.png"))
        let resizedURL = try TestMedia.writeImage(TestMedia.resized(original, width: 600, height: 450),
                                                  to: temp.url.appendingPathComponent("resized.jpg"), type: .jpeg)
        let otherURL = try TestMedia.writeImage(TestMedia.makeImage(width: 1200, height: 900, pattern: .stripes),
                                                to: temp.url.appendingPathComponent("other.png"))

        var items = [
            makeItem(path: originalURL.path, format: .png, size: 900, width: 1200, height: 900),
            makeItem(path: resizedURL.path, format: .jpeg, size: 300, width: 600, height: 450),
            makeItem(path: otherURL.path, format: .png, size: 800, width: 1200, height: 900),
        ]
        let hashes = try await SimilarityDetectionService().computeHashes(for: items)
        XCTAssertEqual(hashes.count, 3)
        for index in items.indices {
            items[index].perceptualHash = hashes[items[index].id]?.perceptual
            items[index].differenceHash = hashes[items[index].id]?.difference
        }
        let groups = try SimilarityDetectionService.groupSimilar(items, maxDistance: PerceptualHasher.maximumDistance(forSimilarity: 0.9))
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(Set(groups[0].items.map(\.path)), [originalURL.path, resizedURL.path])
        XCTAssertEqual(groups[0].suggestedKeeperID, items[0].id, "higher resolution is suggested as keeper")
    }
}
