import Foundation
import Observation
import OSLog

/// A user-presentable error for alerts.
struct PresentableError: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    init(title: String, error: Error) {
        self.title = title
        message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

enum ScanState: Equatable {
    case idle
    case scanning(ScanProgress)
}

/// The media index, scan locations and scanning lifecycle.
@MainActor
@Observable
final class LibraryStore {
    // MARK: State

    private(set) var locations: [ScanLocation] = []
    private(set) var locationStatuses: [UUID: LocationStatus] = [:]
    private(set) var items: [MediaItem] = []
    private(set) var itemsByID: [MediaItem.ID: MediaItem] = [:]
    private(set) var breakdown: MediaBreakdown = .empty
    /// Increments whenever `items` changes; cheap key for views that cache derived data.
    private(set) var revision = 0
    private(set) var scanState: ScanState = .idle
    private(set) var scanSessions: [ScanSession] = []
    private(set) var lastScanIssues: [ScanIssue] = []
    private(set) var photosAuthorization: PhotosAuthorization
    private(set) var isLoaded = false
    var presentedError: PresentableError?

    /// Called after every successful scan so analysis can refresh.
    @ObservationIgnored var onScanCompleted: (() -> Void)?

    // MARK: Dependencies

    @ObservationIgnored private let persistence: PersistenceController
    @ObservationIgnored private let scanner: MediaScannerService
    @ObservationIgnored private let bookmarks: BookmarkManager
    @ObservationIgnored private let access: LocationAccessManager
    @ObservationIgnored private let photos: PhotosLibraryService
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let policy: ProtectedPathPolicy
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var activeScanID: UUID?

    init(
        persistence: PersistenceController,
        scanner: MediaScannerService,
        bookmarks: BookmarkManager,
        photos: PhotosLibraryService,
        settings: SettingsStore,
        policy: ProtectedPathPolicy = .standard
    ) {
        self.policy = policy
        self.persistence = persistence
        self.scanner = scanner
        self.bookmarks = bookmarks
        self.photos = photos
        self.settings = settings
        access = LocationAccessManager(bookmarks: bookmarks)
        photosAuthorization = photos.authorizationStatus()
    }

    // MARK: Derived

    var isScanning: Bool {
        if case .scanning = scanState { return true }
        return false
    }

    var scanProgress: ScanProgress? {
        if case let .scanning(progress) = scanState { return progress }
        return nil
    }

    var lastScanSession: ScanSession? { scanSessions.first }

    var includesPhotosLibrary: Bool { settings.includePhotosLibrary && photosAuthorization.canRead }

    /// `true` when there is at least one place to scan.
    var hasSources: Bool { !locations.isEmpty || includesPhotosLibrary }

    var photosItems: [MediaItem] { items.filter(\.isPhotosAsset) }

    func items(in locationID: UUID) -> [MediaItem] {
        items.filter { $0.locationID == locationID }
    }

    /// Active security-scoped roots, used by the deletion engine to re-validate paths.
    func authorizedRoots() -> [UUID: URL] {
        var roots: [UUID: URL] = [:]
        for location in locations {
            if let url = access.activeURL(for: location.id) { roots[location.id] = url }
        }
        return roots
    }

    // MARK: Lifecycle

    func bootstrap() async {
        guard !isLoaded else { return }
        async let storedLocations = persistence.locations.load()
        async let storedItems = persistence.mediaIndex.load()
        async let storedSessions = persistence.scanHistory.load()
        locations = await storedLocations
        scanSessions = await storedSessions
        setItems(await storedItems)
        refreshLocationAccess()
        photosAuthorization = photos.authorizationStatus()
        isLoaded = true
    }

    func shutdown() {
        scanTask?.cancel()
        access.deactivateAll()
    }

    /// Resolves bookmarks and starts access for every location, recording availability.
    func refreshLocationAccess() {
        var changed = false
        for index in locations.indices {
            let location = locations[index]
            do {
                let activation = try access.activate(location)
                locationStatuses[location.id] = .available
                if let refreshed = activation.refreshedBookmark {
                    locations[index].bookmarkData = refreshed
                    locations[index].path = activation.url.path
                    changed = true
                }
            } catch {
                let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                locationStatuses[location.id] = .unavailable(reason: reason)
                Logger.access.notice("Location unavailable: \(location.displayName, privacy: .public)")
            }
        }
        if changed { persistLocations() }
    }

    // MARK: Locations

    /// Adds user-picked folders (URLs must come from an open panel so the sandbox grants access).
    func addLocations(_ urls: [URL]) {
        for url in urls {
            do {
                try addLocation(url)
            } catch {
                presentedError = PresentableError(title: "Couldn’t Add Folder", error: error)
            }
        }
    }

    func addLocation(_ url: URL) throws {
        let path = url.standardizedFileURL.path
        if policy.isProtected(path: path) {
            throw CleanLocalError.protectedLocation(path: UserDirectories.abbreviate(path: path))
        }
        if locations.contains(where: { $0.path == path }) {
            throw CleanLocalError.locationAlreadyAdded(path: UserDirectories.abbreviate(path: path))
        }
        let bookmark = try bookmarks.makeBookmark(for: url)
        let values = try? url.resourceValues(forKeys: [.volumeIsRemovableKey, .volumeIsInternalKey])
        let location = ScanLocation(
            displayName: FileManager.default.displayName(atPath: path),
            path: path,
            bookmarkData: bookmark,
            isRemovableVolume: values?.volumeIsRemovable == true || values?.volumeIsInternal == false
        )
        locations.append(location)
        do {
            _ = try access.activate(location)
            locationStatuses[location.id] = .available
        } catch {
            locationStatuses[location.id] = .unavailable(reason: error.localizedDescription)
        }
        persistLocations()
    }

    func removeLocation(_ id: UUID) {
        access.deactivate(id)
        locations.removeAll { $0.id == id }
        locationStatuses.removeValue(forKey: id)
        setItems(items.filter { $0.locationID != id })
        persistLocations()
        persistIndex()
    }

    func setLocation(_ id: UUID, enabled: Bool) {
        guard let index = locations.firstIndex(where: { $0.id == id }) else { return }
        locations[index].isEnabled = enabled
        persistLocations()
    }

    // MARK: Photos

    func requestPhotosAccess() async {
        photosAuthorization = await photos.requestAuthorization()
        if photosAuthorization.canRead { settings.includePhotosLibrary = true }
    }

    func refreshPhotosAuthorization() {
        photosAuthorization = photos.authorizationStatus()
    }

    // MARK: Scanning

    /// Starts a scan in the background. The returned task can be awaited (used by tests).
    @discardableResult
    func startScan() -> Task<Void, Never>? {
        guard !isScanning else { return nil }
        guard hasSources else {
            presentedError = PresentableError(title: "Nothing to Scan", error: CleanLocalError.noLocationsToScan)
            return nil
        }
        let task = Task { [weak self] in _ = await self?.performScan() }
        scanTask = task
        return task
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    private func performScan() async {
        let scanID = UUID()
        activeScanID = scanID
        scanState = .scanning(ScanProgress())
        defer {
            activeScanID = nil
            scanState = .idle
            scanTask = nil
        }

        refreshLocationAccess()
        let enabled = locations.filter(\.isEnabled)
        let roots: [ScanRoot] = enabled.compactMap { location in
            access.activeURL(for: location.id).map { ScanRoot(locationID: location.id, name: location.displayName, url: $0) }
        }
        let previous = itemsByID
        let includePhotos = includesPhotosLibrary
        let startedAt = Date.now

        do {
            var configuration = settings.scanConfiguration
            configuration.policy = policy
            let result = try await scanner.scan(roots: roots, previousItems: previous, configuration: configuration) { [weak self] progress in
                Task { @MainActor [weak self] in self?.applyProgress(progress, scanID: scanID) }
            }

            var photosResult: [MediaItem]?
            if includePhotos {
                var progress = scanProgress ?? ScanProgress()
                progress.phase = .photosLibrary
                progress.currentLocationName = "Photos Library"
                progress.currentPath = ""
                scanState = .scanning(progress)
                let base = progress
                photosResult = try await photos.fetchItems(existing: previous) { [weak self] done, total in
                    Task { @MainActor [weak self] in
                        var update = base
                        update.metadataProcessed = done
                        update.metadataTotal = total
                        self?.applyProgress(update, scanID: scanID)
                    }
                }
            }

            if let fetched = photosResult {
                photosResult = await resolveUnknownPhotoSizes(fetched)
            }
            merge(result: result, photosItems: photosResult, includePhotos: includePhotos)
            let finished = Date.now
            for index in locations.indices where result.scannedLocationIDs.contains(locations[index].id) {
                locations[index].lastScannedAt = finished
            }
            lastScanIssues = result.issues
            recordSession(ScanSession(
                id: scanID, startedAt: startedAt, finishedAt: finished,
                locationNames: roots.map(\.name), includedPhotosLibrary: includePhotos,
                mediaCount: items.count, totalBytes: breakdown.totalBytes,
                newItemCount: result.newItemCount + (photosResult?.filter { $0.discoveredAt >= startedAt }.count ?? 0),
                removedItemCount: result.removedItemIDs.count, issueCount: result.issues.count, wasCancelled: false
            ))
            persistLocations()
            persistIndex()
            onScanCompleted?()
        } catch is CancellationError {
            recordSession(ScanSession(
                id: scanID, startedAt: startedAt, finishedAt: .now, locationNames: roots.map(\.name),
                includedPhotosLibrary: includePhotos, mediaCount: items.count, totalBytes: breakdown.totalBytes,
                newItemCount: 0, removedItemCount: 0, issueCount: 0, wasCancelled: true
            ))
        } catch {
            presentedError = PresentableError(title: "Scan Failed", error: error)
        }
    }

    /// Fills in sizes PhotoKit's metadata didn't provide, using the public streaming API.
    private func resolveUnknownPhotoSizes(_ items: [MediaItem]) async -> [MediaItem] {
        let unknown = items.filter { $0.size == 0 }
        guard !unknown.isEmpty else { return items }
        var progress = scanProgress ?? ScanProgress()
        progress.phase = .photosLibrary
        progress.currentPath = "Measuring \(unknown.count) items without size information"
        scanState = .scanning(progress)
        let photos = self.photos
        let sizes = (try? await unknown.concurrentMap(maxConcurrency: 2) { item -> (MediaItem.ID, Int64?) in
            guard let identifier = item.photosLocalIdentifier else { return (item.id, nil) }
            return (item.id, await photos.measuredSize(forLocalIdentifier: identifier))
        }) ?? []
        let resolved = Dictionary(sizes.compactMap { id, size in size.map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        return items.map { item in
            guard let size = resolved[item.id] else { return item }
            var updated = item
            updated.size = size
            return updated
        }
    }

    private func applyProgress(_ progress: ScanProgress, scanID: UUID) {
        // Late updates from a finished scan must not resurrect the scanning state.
        guard activeScanID == scanID, isScanning else { return }
        scanState = .scanning(progress)
    }

    private func merge(result: ScanResult, photosItems: [MediaItem]?, includePhotos: Bool) {
        let knownLocations = Set(locations.map(\.id))
        var merged = items.filter { item in
            switch item.source {
            case let .fileSystem(locationID):
                // Keep items from locations that weren't scanned this time (e.g. unplugged drive).
                return knownLocations.contains(locationID) && !result.scannedLocationIDs.contains(locationID)
            case .photosLibrary:
                return includePhotos && photosItems == nil
            }
        }
        merged += result.items
        merged += photosItems ?? []
        setItems(merged)
    }

    private func recordSession(_ session: ScanSession) {
        scanSessions.insert(session, at: 0)
        if scanSessions.count > 50 { scanSessions.removeLast(scanSessions.count - 50) }
        let sessions = scanSessions
        Task { try? await persistence.scanHistory.save(sessions) }
    }

    // MARK: Index mutations

    /// Removes items after a successful deletion.
    func removeItems(withIDs ids: Set<MediaItem.ID>) {
        guard !ids.isEmpty else { return }
        setItems(items.filter { !ids.contains($0.id) })
        persistIndex()
    }

    func applyContentHashes(_ hashes: [MediaItem.ID: String]) {
        guard !hashes.isEmpty else { return }
        var updated = items
        for index in updated.indices {
            if let hash = hashes[updated[index].id] { updated[index].contentHash = hash }
        }
        setItems(updated)
        persistIndex()
    }

    func applyPerceptualHashes(_ hashes: [MediaItem.ID: PerceptualHasher.Hashes]) {
        guard !hashes.isEmpty else { return }
        var updated = items
        for index in updated.indices {
            if let value = hashes[updated[index].id] {
                updated[index].perceptualHash = value.perceptual
                updated[index].differenceHash = value.difference
            }
        }
        setItems(updated)
        persistIndex()
    }

    func clearIndex() async {
        setItems([])
        scanSessions = []
        lastScanIssues = []
        try? await persistence.mediaIndex.reset()
        try? await persistence.scanHistory.reset()
    }

    func clearScanHistory() async {
        scanSessions = []
        try? await persistence.scanHistory.reset()
    }

    private func setItems(_ newItems: [MediaItem]) {
        items = newItems
        itemsByID = Dictionary(newItems.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        breakdown = StorageAnalyticsService.breakdown(of: newItems)
        revision &+= 1
    }

    // MARK: Persistence

    private func persistLocations() {
        let snapshot = locations
        Task {
            do { try await persistence.locations.save(snapshot) } catch {
                Logger.persistence.error("Saving locations failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func persistIndex() {
        let snapshot = items
        Task {
            do { try await persistence.mediaIndex.save(snapshot) } catch {
                Logger.persistence.error("Saving index failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}
