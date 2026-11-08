import Foundation
import OSLog

/// Moves a file to the Trash. Abstracted so tests never touch the real Trash.
protocol FileTrashing: Sendable {
    /// Returns the item's new location inside the Trash, when known.
    func trashItem(at url: URL) throws -> URL?
}

/// The real implementation: `FileManager.trashItem`, never permanent deletion.
struct SystemTrash: FileTrashing {
    func trashItem(at url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }
}

/// Deletes Photos library assets through PhotoKit.
protocol PhotosAssetDeleting: Sendable {
    /// Returns the identifiers that were actually deleted.
    func deleteAssets(withLocalIdentifiers identifiers: [String]) async throws -> Set<String>
}

/// The only component in CleanLocal that removes anything.
///
/// Every file is re-validated immediately before it is moved, because the filesystem may
/// have changed since the scan:
///
/// 1. It must be inside a location the user authorized, and that location must be reachable.
/// 2. It must not be in a protected system/app location or inside a package.
/// 3. It must be a regular file — never a symbolic link — and its real parent directory
///    must still resolve inside the authorized location (no symlink escapes).
/// 4. Its size and modification date must match the scan (otherwise the user is asked to rescan).
/// 5. It must not be locked.
///
/// Files are moved to the Trash with `FileManager.trashItem`; nothing is permanently erased.
/// Photos assets go through `PHPhotoLibrary.performChanges`, which shows the system's own
/// confirmation and moves them to Recently Deleted.
actor SafeDeletionService {
    private let trash: any FileTrashing
    private let photosDeleter: (any PhotosAssetDeleting)?
    private let policy: ProtectedPathPolicy

    init(trash: any FileTrashing = SystemTrash(), photosDeleter: (any PhotosAssetDeleting)?, policy: ProtectedPathPolicy = .standard) {
        self.trash = trash
        self.photosDeleter = photosDeleter
        self.policy = policy
    }

    /// Removes the given items. Never throws: each item gets its own success/failure record.
    ///
    /// - Parameter authorizedRoots: Active security-scoped roots keyed by location ID.
    func remove(_ items: [MediaItem], authorizedRoots: [UUID: URL]) async -> DeletionReport {
        let batchID = UUID()
        var records: [DeletionRecord] = []

        for item in items where !item.isPhotosAsset {
            records.append(trashFile(item, authorizedRoots: authorizedRoots, batchID: batchID))
        }

        let photosItems = items.filter(\.isPhotosAsset)
        if !photosItems.isEmpty {
            records += await deletePhotosAssets(photosItems, batchID: batchID)
        }

        let succeeded = records.filter { $0.status.succeeded }.count
        Logger.deletion.info("Deletion batch \(batchID.uuidString, privacy: .public): \(succeeded)/\(records.count) succeeded")
        return DeletionReport(id: batchID, records: records)
    }

    // MARK: - Files

    private func trashFile(_ item: MediaItem, authorizedRoots: [UUID: URL], batchID: UUID) -> DeletionRecord {
        let validated = validate(item, authorizedRoots: authorizedRoots)
        switch validated {
        case let .failure(error):
            return record(for: item, batchID: batchID, status: .failed, error: error)
        case let .success(url):
            do {
                let trashedURL = try trash.trashItem(at: url)
                return record(for: item, batchID: batchID, status: .movedToTrash, trashedPath: trashedURL?.path)
            } catch {
                return record(for: item, batchID: batchID, status: .failed, error: Self.map(error, path: url.path))
            }
        }
    }

    /// Re-checks every safety rule against the live filesystem.
    nonisolated func validate(_ item: MediaItem, authorizedRoots: [UUID: URL]) -> Result<URL, CleanLocalError> {
        guard let path = item.path, let locationID = item.locationID else {
            return .failure(.notARegularFile(path: item.filename))
        }
        if policy.isProtected(path: path) { return .failure(.protectedLocation(path: path)) }

        guard let root = authorizedRoots[locationID] else {
            return .failure(.outsideAuthorizedLocations(path: path))
        }
        let rootPath = root.standardizedFileURL.path
        guard path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else {
            return .failure(.outsideAuthorizedLocations(path: path))
        }
        guard FileManager.default.fileExists(atPath: rootPath) else {
            return .failure(.volumeUnavailable(path: path))
        }

        // attributesOfItem does not traverse a symlink at the final path component.
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try FileManager.default.attributesOfItem(atPath: path)
        } catch {
            return .failure(.fileNotFound(path: path))
        }
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            return .failure(.symbolicLinkRefused(path: path))
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .failure(.notARegularFile(path: path))
        }

        // Guard against symlinked parent directories that escape the authorized root.
        let url = URL(fileURLWithPath: path)
        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        let resolvedRoot = root.resolvingSymlinksInPath().path
        guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else {
            return .failure(.outsideAuthorizedLocations(path: path))
        }
        if policy.isProtected(path: resolvedParent) { return .failure(.protectedLocation(path: path)) }

        let currentSize = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let currentModified = attributes[.modificationDate] as? Date
        guard item.hasSameContentSignature(size: currentSize, modificationDate: currentModified) else {
            return .failure(.fileChangedSinceScan(path: path))
        }
        if (attributes[.immutable] as? NSNumber)?.boolValue == true {
            return .failure(.fileLocked(path: path))
        }
        return .success(url)
    }

    /// Translates Cocoa/POSIX errors into precise, user-presentable errors.
    static func map(_ error: Error, path: String) -> CleanLocalError {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain {
            switch nsError.code {
            case NSFileNoSuchFileError, NSFileReadNoSuchFileError: return .fileNotFound(path: path)
            case NSFileWriteNoPermissionError, NSFileReadNoPermissionError: return .permissionDenied(path: path)
            case NSFileWriteVolumeReadOnlyError: return .readOnlyVolume(path: path)
            case NSFileLockingError: return .fileLocked(path: path)
            default: break
            }
        }
        let posix = nsError.domain == NSPOSIXErrorDomain ? nsError : nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        if let posix, posix.domain == NSPOSIXErrorDomain {
            switch Int32(posix.code) {
            case ENOENT: return .fileNotFound(path: path)
            case EACCES, EPERM: return .permissionDenied(path: path)
            case EROFS: return .readOnlyVolume(path: path)
            case EBUSY, ETXTBSY: return .fileInUse(path: path)
            case ENXIO, ENODEV, EIO: return .volumeUnavailable(path: path)
            default: break
            }
        }
        return .trashFailed(path: path, reason: nsError.localizedDescription)
    }

    // MARK: - Photos

    private func deletePhotosAssets(_ items: [MediaItem], batchID: UUID) async -> [DeletionRecord] {
        guard let photosDeleter else {
            return items.map { record(for: $0, batchID: batchID, status: .failed, error: .photosAuthorizationDenied) }
        }
        let identifiers = items.compactMap(\.photosLocalIdentifier)
        do {
            let deleted = try await photosDeleter.deleteAssets(withLocalIdentifiers: identifiers)
            return items.map { item in
                if let identifier = item.photosLocalIdentifier, deleted.contains(identifier) {
                    return record(for: item, batchID: batchID, status: .removedFromPhotos)
                }
                return record(for: item, batchID: batchID, status: .failed,
                              error: .photosAssetUnavailable(identifier: item.photosLocalIdentifier ?? item.id))
            }
        } catch {
            let mapped = (error as? CleanLocalError) ?? .photosChangeFailed(reason: error.localizedDescription)
            return items.map { record(for: $0, batchID: batchID, status: .failed, error: mapped) }
        }
    }

    // MARK: - Records

    private func record(
        for item: MediaItem,
        batchID: UUID,
        status: DeletionRecord.Status,
        error: CleanLocalError? = nil,
        trashedPath: String? = nil
    ) -> DeletionRecord {
        DeletionRecord(
            id: UUID(),
            batchID: batchID,
            itemID: item.id,
            filename: item.filename,
            originalLocation: item.path ?? "Photos Library",
            size: item.size,
            timestamp: .now,
            status: status,
            errorDescription: error?.errorDescription,
            trashedPath: trashedPath,
            wasPhotosAsset: item.isPhotosAsset
        )
    }
}
