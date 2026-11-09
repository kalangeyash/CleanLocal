import AVFoundation
import CryptoKit
import Foundation
import OSLog
import Photos

/// Apple Photos integration through PhotoKit.
///
/// CleanLocal never reads or writes inside the `.photoslibrary` package directly. All reads
/// go through PhotoKit, and deletions go through `PHPhotoLibrary.performChanges`, which
/// shows the system's own confirmation and moves assets to Recently Deleted.
///
/// Network access is disabled for every request: iCloud-only originals are skipped rather
/// than downloaded.
///
/// `@unchecked Sendable`: the only stored property is a PhotoKit image manager, which is
/// documented as safe to use from any thread.
final class PhotosLibraryService: PhotosImageProviding, PhotosContentHashing, PhotosAssetDeleting, @unchecked Sendable {
    private let imageManager = PHCachingImageManager()

    // MARK: - Authorization

    func authorizationStatus() -> PhotosAuthorization {
        Self.map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    func requestAuthorization() async -> PhotosAuthorization {
        Self.map(await PHPhotoLibrary.requestAuthorization(for: .readWrite))
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotosAuthorization {
        switch status {
        case .authorized: .authorized
        case .limited: .limited
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    // MARK: - Fetching

    /// Indexes every photo and video asset. Assets whose modification date is unchanged
    /// are reused from `existing` to avoid repeated resource lookups.
    func fetchItems(
        existing: [MediaItem.ID: MediaItem],
        progress: @escaping @Sendable (Int, Int) -> Void
    ) async throws -> [MediaItem] {
        guard authorizationStatus().canRead else { throw CleanLocalError.photosAuthorizationDenied }

        let options = PHFetchOptions()
        options.includeHiddenAssets = false
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )
        let result = PHAsset.fetchAssets(with: options)
        let count = result.count
        let now = Date.now
        var items: [MediaItem] = []
        items.reserveCapacity(count)

        for index in 0..<count {
            if index.isMultiple(of: 200) {
                try Task.checkCancellation()
                progress(index, count)
            }
            let asset = result.object(at: index)
            let id = MediaItem.photosID(forLocalIdentifier: asset.localIdentifier)
            if var previous = existing[id], previous.modificationDate == asset.modificationDate {
                previous.lastScannedAt = now
                items.append(previous)
                continue
            }
            items.append(autoreleasepool { makeItem(for: asset, id: id, previous: existing[id], now: now) })
        }
        progress(count, count)
        Logger.photos.info("Indexed \(items.count) Photos assets")
        return items
    }

    private func makeItem(for asset: PHAsset, id: MediaItem.ID, previous: MediaItem?, now: Date) -> MediaItem {
        let resources = PHAssetResource.assetResources(for: asset)
        let original = Self.originalResource(in: resources)
        let filename = original?.originalFilename ?? "Untitled"
        let format = MediaFormat.from(fileExtension: (filename as NSString).pathExtension)
        let kind: MediaKind = asset.mediaType == .video ? .video : .image
        // Deleting an asset frees all of its resources (original, edits, Live Photo video).
        let size = resources.reduce(Int64(0)) { $0 + Self.fileSize(of: $1) }

        return MediaItem(
            id: id,
            source: .photosLibrary,
            path: nil,
            photosLocalIdentifier: asset.localIdentifier,
            filename: filename,
            format: format,
            kind: kind,
            size: size,
            creationDate: asset.creationDate,
            modificationDate: asset.modificationDate,
            captureDate: asset.creationDate,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            duration: kind == .video ? asset.duration : nil,
            isScreenshot: asset.mediaSubtypes.contains(.photoScreenshot),
            discoveredAt: previous?.discoveredAt ?? now,
            lastScannedAt: now,
            contentHash: nil,
            perceptualHash: nil,
            differenceHash: nil
        )
    }

    private static func originalResource(in resources: [PHAssetResource]) -> PHAssetResource? {
        resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
    }

    /// PhotoKit has no public file-size API. `fileSize` is read via KVC only when the
    /// resource responds to it; otherwise the size is reported as unknown (0).
    private static func fileSize(of resource: PHAssetResource) -> Int64 {
        guard resource.responds(to: NSSelectorFromString("fileSize")) else { return 0 }
        return (resource.value(forKey: "fileSize") as? NSNumber)?.int64Value ?? 0
    }

    private func asset(for identifier: String) -> PHAsset? {
        PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject
    }

    // MARK: - Albums

    func fetchAlbums() -> [PhotoAlbum] {
        guard authorizationStatus().canRead else { return [] }
        var albums: [PhotoAlbum] = []
        let mediaOptions = PHFetchOptions()
        mediaOptions.predicate = NSPredicate(
            format: "mediaType == %d || mediaType == %d",
            PHAssetMediaType.image.rawValue, PHAssetMediaType.video.rawValue
        )

        func collect(_ type: PHAssetCollectionType, smart: Bool) {
            let collections = PHAssetCollection.fetchAssetCollections(with: type, subtype: .any, options: nil)
            collections.enumerateObjects { collection, _, _ in
                let count = PHAsset.fetchAssets(in: collection, options: mediaOptions).count
                guard count > 0 else { return }
                albums.append(PhotoAlbum(
                    id: collection.localIdentifier,
                    title: collection.localizedTitle ?? "Untitled Album",
                    assetCount: count,
                    isSmartAlbum: smart
                ))
            }
        }
        collect(.smartAlbum, smart: true)
        collect(.album, smart: false)
        return albums
    }

    /// Media item IDs contained in an album.
    func itemIDs(inAlbum albumID: String) -> Set<MediaItem.ID> {
        guard let collection = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumID], options: nil).firstObject
        else { return [] }
        var ids = Set<MediaItem.ID>()
        PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
            ids.insert(MediaItem.photosID(forLocalIdentifier: asset.localIdentifier))
        }
        return ids
    }

    // MARK: - Images & video

    func image(forLocalIdentifier identifier: String, targetPixelSize: CGFloat) async -> RenderedImage? {
        guard let asset = asset(for: identifier) else { return nil }
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let contentMode: PHImageContentMode = targetPixelSize > 1000 ? .aspectFit : .aspectFill

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(
                for: asset,
                targetSize: CGSize(width: targetPixelSize, height: targetPixelSize),
                contentMode: contentMode,
                options: options
            ) { image, _ in
                let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                continuation.resume(returning: cgImage.map(RenderedImage.init))
            }
        }
    }

    /// A player for the asset's video, when its original is available locally.
    @MainActor
    func player(forLocalIdentifier identifier: String) async -> AVPlayer? {
        guard let asset = await videoAsset(forLocalIdentifier: identifier).value else { return nil }
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    private func videoAsset(forLocalIdentifier identifier: String) async -> UncheckedSendableBox<AVAsset?> {
        guard let asset = asset(for: identifier), asset.mediaType == .video else { return UncheckedSendableBox(value: nil) }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        return await withCheckedContinuation { continuation in
            imageManager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                // AVAsset is documented as safe to load from any thread.
                continuation.resume(returning: UncheckedSendableBox(value: avAsset))
            }
        }
    }

    // MARK: - Hashing

    func contentHash(forLocalIdentifier identifier: String, allowNetwork: Bool = false) async throws -> String {
        guard let asset = asset(for: identifier),
              let resource = Self.originalResource(in: PHAssetResource.assetResources(for: asset)) else {
            throw CleanLocalError.photosAssetUnavailable(identifier: identifier)
        }
        let options = PHAssetResourceRequestOptions()
        // Photos (not CleanLocal) performs any iCloud download, and only with the user's opt-in.
        options.isNetworkAccessAllowed = allowNetwork
        let accumulator = StreamingSHA256()
        let manager = PHAssetResourceManager.default()
        let requestID = RequestIDBox()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                requestID.value = manager.requestData(
                    for: resource,
                    options: options,
                    dataReceivedHandler: { accumulator.update($0) },
                    completionHandler: { error in
                        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                    }
                )
            }
        } onCancel: {
            if let id = requestID.value { manager.cancelDataRequest(id) }
        }
        return accumulator.finalize()
    }

    /// Measures an asset's size with public PhotoKit APIs by streaming its resources and
    /// counting bytes (nothing is stored). Returns `nil` when an original isn't available
    /// locally. Used only when the fast metadata path can't report a size.
    func measuredSize(forLocalIdentifier identifier: String) async -> Int64? {
        guard let asset = asset(for: identifier) else { return nil }
        let manager = PHAssetResourceManager.default()
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = false
        var total: Int64 = 0
        for resource in PHAssetResource.assetResources(for: asset) {
            let counter = ByteCounter()
            let ok: Bool = await withCheckedContinuation { continuation in
                manager.requestData(for: resource, options: options,
                                    dataReceivedHandler: { counter.add($0.count) },
                                    completionHandler: { continuation.resume(returning: $0 == nil) })
            }
            guard ok else { return nil }
            total += counter.value
        }
        return total > 0 ? total : nil
    }

    func perceptualHashes(forLocalIdentifier identifier: String) async -> PerceptualHasher.Hashes? {
        guard let image = await image(forLocalIdentifier: identifier, targetPixelSize: CGFloat(PerceptualHasher.thumbnailPixelSize)) else {
            return nil
        }
        return PerceptualHasher.hashes(for: image.cgImage)
    }

    // MARK: - Deletion

    func deleteAssets(withLocalIdentifiers identifiers: [String]) async throws -> Set<String> {
        guard authorizationStatus().canRead else { throw CleanLocalError.photosAuthorizationDenied }
        let existing = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var present = Set<String>()
        existing.enumerateObjects { asset, _, _ in present.insert(asset.localIdentifier) }
        guard !present.isEmpty else { return [] }

        let targets = Array(present)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let assets = PHAsset.fetchAssets(withLocalIdentifiers: targets, options: nil)
                PHAssetChangeRequest.deleteAssets(assets)
            }
        } catch let error as PHPhotosError where error.code == .userCancelled {
            throw CleanLocalError.photosDeletionCancelled
        } catch {
            throw CleanLocalError.photosChangeFailed(reason: error.localizedDescription)
        }
        return present
    }
}

/// SHA-256 fed incrementally from PhotoKit's data callbacks.
private final class StreamingSHA256: @unchecked Sendable {
    private let lock = NSLock()
    private var hasher = SHA256()

    func update(_ data: Data) {
        lock.withLock { hasher.update(data: data) }
    }

    func finalize() -> String {
        lock.withLock { hasher.finalize().hexString }
    }
}

/// Carries a value Apple documents as thread-safe but that isn't annotated `Sendable`.
struct UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
}

private final class ByteCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ count: Int) { lock.withLock { total += Int64(count) } }
    var value: Int64 { lock.withLock { total } }
}

private final class RequestIDBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: PHAssetResourceDataRequestID?

    var value: PHAssetResourceDataRequestID? {
        get { lock.withLock { storage } }
        set { lock.withLock { storage = newValue } }
    }
}
