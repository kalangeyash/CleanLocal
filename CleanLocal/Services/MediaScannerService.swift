import Foundation
import OSLog

/// Options that shape a scan.
struct ScanConfiguration: Sendable {
    var classifier = MediaTypeClassifier()
    var includeHiddenFiles = false
    var policy = ProtectedPathPolicy.standard
    var metadataConcurrency = AppConstants.Scanning.metadataConcurrency
}

/// Discovers media files under user-authorized folders and reads their metadata.
///
/// * Traversal never follows symbolic links, never descends into packages (apps,
///   `.photoslibrary`, …) and skips protected system locations.
/// * Metadata extraction runs with bounded concurrency.
/// * Incremental: files whose size and modification date are unchanged since the
///   previous scan are reused as-is (including cached hashes) instead of re-read.
/// * Cooperative cancellation is honored throughout.
actor MediaScannerService {
    private let metadataService: MediaMetadataService
    private let screenshotDetector: ScreenshotDetector
    private var isScanning = false

    init(metadataService: MediaMetadataService = MediaMetadataService(), screenshotDetector: ScreenshotDetector = ScreenshotDetector()) {
        self.metadataService = metadataService
        self.screenshotDetector = screenshotDetector
    }

    /// Scans `roots`. The caller is responsible for having started security-scoped access.
    ///
    /// - Parameters:
    ///   - previousItems: The current index, keyed by item ID, used for incremental reuse.
    ///   - progress: Called (throttled) from background tasks with live progress.
    func scan(
        roots: [ScanRoot],
        previousItems: [MediaItem.ID: MediaItem],
        configuration: ScanConfiguration = ScanConfiguration(),
        progress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> ScanResult {
        guard !isScanning else { throw CleanLocalError.scanAlreadyRunning }
        isScanning = true
        defer { isScanning = false }

        let startedAt = Date.now
        let reporter = ProgressReporter(callback: progress)
        let issues = IssueCollector()

        // Phase 1: discovery (synchronous traversal off the main actor).
        var discovered: [DiscoveredFile] = []
        var visitedPaths = Set<String>()
        for root in roots {
            try Task.checkCancellation()
            reporter.update(force: true) {
                $0.phase = .discovering
                $0.currentLocationName = root.name
                $0.currentPath = UserDirectories.abbreviate(path: root.url.path)
            }
            discovered += try Self.discover(
                root: root, configuration: configuration, visitedPaths: &visitedPaths,
                issues: issues, reporter: reporter
            )
        }

        // Phase 2: decide what can be reused.
        let now = Date.now
        var reused: [MediaItem] = []
        var needsMetadata: [(DiscoveredFile, MediaItem?)] = []
        for file in discovered {
            let previous = previousItems[MediaItem.fileID(forPath: file.path)]
            if var previous, previous.hasSameContentSignature(size: file.size, modificationDate: file.modificationDate) {
                previous.source = .fileSystem(locationID: file.locationID)
                previous.lastScannedAt = now
                // Clone relationships can change without content changing; refresh cheaply.
                if let space = FileSpaceInspector.inspect(url: file.url) {
                    previous.reclaimableSize = space.reclaimableSize
                    previous.cloneID = space.cloneID
                }
                reused.append(previous)
            } else {
                needsMetadata.append((file, previous))
            }
        }

        // Phase 3: metadata for new or changed files, with bounded concurrency.
        reporter.update(force: true) {
            $0.phase = .readingMetadata
            $0.metadataTotal = needsMetadata.count
            $0.metadataProcessed = 0
        }
        let metadataService = self.metadataService
        let detector = self.screenshotDetector
        let fresh = try await needsMetadata.concurrentMap(maxConcurrency: configuration.metadataConcurrency) { file, previous in
            try Task.checkCancellation()
            let metadata = await metadataService.metadata(for: file.url, kind: file.format.kind)
            reporter.update {
                $0.metadataProcessed += 1
                $0.currentPath = UserDirectories.abbreviate(path: file.path)
            }
            return Self.makeItem(file: file, metadata: metadata, previous: previous, detector: detector, now: now)
        }

        reporter.update(force: true) { $0.phase = .finalizing }

        let scannedLocationIDs = Set(roots.map(\.locationID))
        let foundIDs = Set(discovered.map { MediaItem.fileID(forPath: $0.path) })
        let removed = previousItems.values
            .filter { item in item.locationID.map(scannedLocationIDs.contains) ?? false }
            .map(\.id)
            .filter { !foundIDs.contains($0) }

        let result = ScanResult(
            items: reused + fresh,
            issues: issues.all,
            newItemCount: needsMetadata.filter { $0.1 == nil }.count,
            reusedItemCount: reused.count,
            removedItemIDs: Set(removed),
            scannedLocationIDs: scannedLocationIDs,
            startedAt: startedAt,
            finishedAt: .now
        )
        Logger.scanning.info("Scan finished: \(result.items.count) items, \(result.newItemCount) new, \(result.reusedItemCount) reused, \(result.issues.count) issues")
        return result
    }

    // MARK: - Discovery

    struct DiscoveredFile: Sendable {
        let url: URL
        let path: String
        let locationID: UUID
        let format: MediaFormat
        let size: Int64
        let creationDate: Date?
        let modificationDate: Date?
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .isPackageKey,
        .fileSizeKey, .creationDateKey, .contentModificationDateKey,
    ]

    private static func discover(
        root: ScanRoot,
        configuration: ScanConfiguration,
        visitedPaths: inout Set<String>,
        issues: IssueCollector,
        reporter: ProgressReporter
    ) throws -> [DiscoveredFile] {
        let rootPath = root.url.path
        if let reason = configuration.policy.protectionReason(for: rootPath) {
            issues.append(ScanIssue(path: rootPath, reason: "Skipped: \(reason)"))
            return []
        }

        var options: FileManager.DirectoryEnumerationOptions = [.skipsPackageDescendants]
        if !configuration.includeHiddenFiles { options.insert(.skipsHiddenFiles) }

        guard let enumerator = FileManager.default.enumerator(
            at: root.url,
            includingPropertiesForKeys: resourceKeys,
            options: options,
            errorHandler: { url, error in
                issues.append(ScanIssue(path: url.path, reason: error.localizedDescription))
                return true // keep going; one unreadable folder must not abort the scan
            }
        ) else {
            issues.append(ScanIssue(path: rootPath, reason: "The folder could not be opened"))
            return []
        }

        let keySet = Set(resourceKeys)
        var results: [DiscoveredFile] = []
        while let next = enumerator.nextObject() {
            guard let url = next as? URL else { continue }
            if Task.isCancelled { throw CancellationError() }
            reporter.update { $0.filesVisited += 1 }

            guard let values = try? url.resourceValues(forKeys: keySet) else { continue }
            // Symbolic links are never followed nor indexed (prevents loops and escapes).
            if values.isSymbolicLink == true { continue }

            if values.isDirectory == true {
                if values.isPackage == true || configuration.policy.isProtected(path: url.path) {
                    enumerator.skipDescendants()
                }
                continue
            }

            guard values.isRegularFile == true,
                  let format = configuration.classifier.format(for: url) else { continue }

            let path = url.path
            guard visitedPaths.insert(path).inserted, !configuration.policy.isProtected(path: path) else { continue }

            results.append(DiscoveredFile(
                url: url,
                path: path,
                locationID: root.locationID,
                format: format,
                size: Int64(values.fileSize ?? 0),
                creationDate: values.creationDate,
                modificationDate: values.contentModificationDate
            ))
            reporter.update {
                $0.mediaFound += 1
                $0.currentPath = UserDirectories.abbreviate(path: path)
            }
        }
        reporter.update(force: true) { $0.issuesCount = issues.count }
        return results
    }

    private static func makeItem(
        file: DiscoveredFile,
        metadata: MediaMetadata,
        previous: MediaItem?,
        detector: ScreenshotDetector,
        now: Date
    ) -> MediaItem {
        let filename = file.url.lastPathComponent
        let directory = file.url.deletingLastPathComponent().path
        var item = MediaItem(
            id: MediaItem.fileID(forPath: file.path),
            source: .fileSystem(locationID: file.locationID),
            path: file.path,
            photosLocalIdentifier: nil,
            filename: filename,
            format: file.format,
            kind: file.format.kind,
            size: file.size,
            creationDate: file.creationDate,
            modificationDate: file.modificationDate,
            captureDate: metadata.captureDate,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            duration: metadata.duration,
            isScreenshot: detector.isScreenshot(
                filename: filename, directoryPath: directory,
                format: file.format, exifUserComment: metadata.exifUserComment
            ),
            discoveredAt: previous?.discoveredAt ?? now,
            lastScannedAt: now,
            // Content changed (or brand-new): cached hashes are not carried over.
            contentHash: nil,
            perceptualHash: nil,
            differenceHash: nil
        )
        // Real space accounting: clones and hard links free less than their size.
        if let space = FileSpaceInspector.inspect(url: file.url) {
            item.reclaimableSize = space.reclaimableSize
            item.cloneID = space.cloneID
        }
        return item
    }
}

// MARK: - Thread-safe helpers

/// Collects non-fatal scan issues from the enumerator callback and worker tasks.
final class IssueCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [ScanIssue] = []
    private static let limit = 500

    func append(_ issue: ScanIssue) {
        lock.withLock {
            if issues.count < Self.limit { issues.append(issue) }
        }
    }

    var all: [ScanIssue] { lock.withLock { issues } }
    var count: Int { lock.withLock { issues.count } }
}

/// Holds the latest progress snapshot and forwards it, throttled, to the UI.
final class ProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var progress = ScanProgress()
    private var throttle = ProgressThrottle()
    private let callback: @Sendable (ScanProgress) -> Void

    init(callback: @escaping @Sendable (ScanProgress) -> Void) {
        self.callback = callback
    }

    func update(force: Bool = false, _ change: (inout ScanProgress) -> Void) {
        let snapshot: ScanProgress? = lock.withLock {
            change(&progress)
            return throttle.shouldFire(force: force) ? progress : nil
        }
        if let snapshot { callback(snapshot) }
    }
}
