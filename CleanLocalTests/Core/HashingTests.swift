import XCTest
@testable import CleanLocal

final class FileHasherTests: XCTestCase {
    private var temp: TemporaryDirectory!

    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testSHA256MatchesKnownVector() throws {
        let file = try temp.writeData(Data("abc".utf8), to: "abc.bin")
        XCTAssertEqual(try FileHasher.sha256(of: file), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testSHA256IsIndependentOfChunkSize() throws {
        let data = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let file = try temp.writeData(data, to: "big.bin")
        XCTAssertEqual(try FileHasher.sha256(of: file, chunkSize: 4096), try FileHasher.sha256(of: file, chunkSize: 1 << 20))
    }

    func testEdgeFingerprintIgnoresMiddleButFullHashDoesNot() throws {
        var a = Data(repeating: 1, count: 300_000)
        var b = a
        a[150_000] = 7
        b[150_000] = 9
        let fileA = try temp.writeData(a, to: "a.bin")
        let fileB = try temp.writeData(b, to: "b.bin")
        XCTAssertEqual(try FileHasher.edgeFingerprint(of: fileA), try FileHasher.edgeFingerprint(of: fileB))
        XCTAssertNotEqual(try FileHasher.sha256(of: fileA), try FileHasher.sha256(of: fileB))
    }

    func testMissingFileThrows() {
        XCTAssertThrowsError(try FileHasher.sha256(of: temp.url.appendingPathComponent("missing.bin")))
    }
}

final class PerceptualHasherTests: XCTestCase {
    private var temp: TemporaryDirectory!

    override func setUpWithError() throws { temp = try TemporaryDirectory() }
    override func tearDown() { temp.cleanUp() }

    func testResizedAndRecompressedCopyIsSimilar() throws {
        let original = TestMedia.makeImage(width: 1200, height: 900, pattern: .gradientWithDisc)
        let originalURL = try TestMedia.writeImage(original, to: temp.url.appendingPathComponent("original.png"))
        let copyURL = try TestMedia.writeImage(
            TestMedia.resized(original, width: 400, height: 300),
            to: temp.url.appendingPathComponent("copy.jpg"), type: .jpeg,
            properties: [kCGImageDestinationLossyCompressionQuality: 0.5]
        )
        let a = try XCTUnwrap(PerceptualHasher.hashes(forImageAt: originalURL))
        let b = try XCTUnwrap(PerceptualHasher.hashes(forImageAt: copyURL))
        XCTAssertLessThanOrEqual(PerceptualHasher.distance(a.perceptual, b.perceptual), 6)
        XCTAssertLessThanOrEqual(PerceptualHasher.distance(a.difference, b.difference), 10)
    }

    func testDifferentImagesAreFarApart() throws {
        let a = try XCTUnwrap(PerceptualHasher.hashes(for: TestMedia.makeImage(pattern: .gradientWithDisc)))
        let b = try XCTUnwrap(PerceptualHasher.hashes(for: TestMedia.makeImage(pattern: .stripes)))
        XCTAssertGreaterThan(PerceptualHasher.distance(a.perceptual, b.perceptual), 16)
    }

    func testIdenticalImagesHaveZeroDistance() throws {
        let image = TestMedia.makeImage(pattern: .checkerboard(cell: 40))
        let a = try XCTUnwrap(PerceptualHasher.hashes(for: image))
        let b = try XCTUnwrap(PerceptualHasher.hashes(for: image))
        XCTAssertEqual(a, b)
    }

    func testThresholdMapping() {
        XCTAssertEqual(PerceptualHasher.maximumDistance(forSimilarity: 1.0), 0)
        XCTAssertEqual(PerceptualHasher.maximumDistance(forSimilarity: 0.9), 6)
        XCTAssertEqual(PerceptualHasher.maximumDistance(forSimilarity: 0.0), 32, "clamped to 50%")
        XCTAssertEqual(PerceptualHasher.distance(0b1011, 0b0001), 2)
    }
}

final class ConcurrencyTests: XCTestCase {
    func testConcurrentMapPreservesOrderAndBoundsConcurrency() async throws {
        let tracker = ConcurrencyTracker()
        let output = try await Array(0..<50).concurrentMap(maxConcurrency: 3) { value -> Int in
            await tracker.enter()
            try await Task.sleep(for: .milliseconds(2))
            await tracker.leave()
            return value * 2
        }
        XCTAssertEqual(output, (0..<50).map { $0 * 2 })
        let peak = await tracker.peak
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 1)
    }

    func testConcurrentMapPropagatesCancellation() async {
        let task = Task {
            try await Array(0..<1000).concurrentMap(maxConcurrency: 2) { value -> Int in
                try await Task.sleep(for: .milliseconds(20))
                return value
            }
        }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}

private actor ConcurrencyTracker {
    private var current = 0
    private(set) var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
