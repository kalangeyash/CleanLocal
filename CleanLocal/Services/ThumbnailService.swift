import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// An immutable decoded image that can cross concurrency domains (CGImage is immutable).
struct RenderedImage: @unchecked Sendable {
    let cgImage: CGImage
    var pixelSize: CGSize { CGSize(width: cgImage.width, height: cgImage.height) }
}

/// Supplies images for Photos library assets (implemented with PhotoKit).
protocol PhotosImageProviding: Sendable {
    func image(forLocalIdentifier identifier: String, targetPixelSize: CGFloat) async -> RenderedImage?
}

/// Generates and caches thumbnails and preview images.
///
/// * Two-level cache: an in-memory `NSCache` (cost-limited) and small JPEGs on disk in the
///   app's Caches directory, keyed by path + size + modification date so edits invalidate them.
/// * Generation is capped by a semaphore so fast scrolling cannot launch hundreds of decodes.
/// * Grid cells always receive downsampled images; full-resolution decoding never happens.
///
/// `@unchecked Sendable`: all stored properties are immutable or thread-safe (`NSCache`).
final class ThumbnailService: @unchecked Sendable {
    private final class CacheEntry {
        let image: RenderedImage
        init(_ image: RenderedImage) { self.image = image }
    }

    private let memoryCache = NSCache<NSString, CacheEntry>()
    private let diskCacheDirectory: URL
    private let limiter = AsyncSemaphore(permits: AppConstants.Thumbnails.maxConcurrentGenerations)
    private let photosProvider: (any PhotosImageProviding)?

    init(diskCacheDirectory: URL, photosProvider: (any PhotosImageProviding)?) {
        self.diskCacheDirectory = diskCacheDirectory
        self.photosProvider = photosProvider
        memoryCache.totalCostLimit = AppConstants.Thumbnails.memoryCacheCostLimit
    }

    static func defaultDiskCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("Thumbnails", isDirectory: true)
    }

    // MARK: - Public API

    /// Returns a cached image synchronously if it is already in memory (avoids flicker).
    func cachedThumbnail(for item: MediaItem, pixelSize: CGFloat) -> RenderedImage? {
        memoryCache.object(forKey: cacheKey(for: item, pixelSize: pixelSize) as NSString)?.image
    }

    func thumbnail(for item: MediaItem, pixelSize: CGFloat) async -> RenderedImage? {
        let key = cacheKey(for: item, pixelSize: pixelSize)
        if let cached = memoryCache.object(forKey: key as NSString) { return cached.image }

        if !item.isPhotosAsset, let fromDisk = readDiskCache(key: key) {
            store(fromDisk, key: key)
            return fromDisk
        }

        await limiter.acquire()
        // The cell may have scrolled away while waiting for a permit.
        let generated = Task.isCancelled ? nil : await generate(item: item, pixelSize: pixelSize)
        await limiter.release()

        if let generated {
            store(generated, key: key)
            if !item.isPhotosAsset { writeDiskCache(generated, key: key) }
        }
        return generated
    }

    private func generate(item: MediaItem, pixelSize: CGFloat) async -> RenderedImage? {
        if item.isPhotosAsset {
            guard let identifier = item.photosLocalIdentifier else { return nil }
            return await photosProvider?.image(forLocalIdentifier: identifier, targetPixelSize: pixelSize)
        }
        guard let url = item.url else { return nil }
        return await generateFileThumbnail(url: url, kind: item.kind, pixelSize: pixelSize)
    }

    /// A screen-sized, downsampled image for the preview window.
    func previewImage(for item: MediaItem) async -> RenderedImage? {
        let size = AppConstants.Thumbnails.previewPixelSize
        if item.isPhotosAsset {
            guard let identifier = item.photosLocalIdentifier else { return nil }
            return await photosProvider?.image(forLocalIdentifier: identifier, targetPixelSize: size)
        }
        guard let url = item.url else { return nil }
        if item.kind == .image, let image = Self.downsampledImage(at: url, maxPixelSize: size) {
            return image
        }
        return await generateFileThumbnail(url: url, kind: item.kind, pixelSize: size)
    }

    func clearCaches() throws {
        memoryCache.removeAllObjects()
        if FileManager.default.fileExists(atPath: diskCacheDirectory.path) {
            try FileManager.default.removeItem(at: diskCacheDirectory)
        }
    }

    func diskCacheSize() -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: diskCacheDirectory, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]
        ) else { return 0 }
        var total: Int64 = 0
        while let url = enumerator.nextObject() as? URL {
            total += Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    // MARK: - Generation

    private func generateFileThumbnail(url: URL, kind: MediaKind, pixelSize: CGFloat) async -> RenderedImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pixelSize, height: pixelSize),
            scale: 1,
            representationTypes: .thumbnail
        )
        if let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            return RenderedImage(cgImage: representation.cgImage)
        }
        switch kind {
        case .image:
            return Self.downsampledImage(at: url, maxPixelSize: pixelSize)
        case .video:
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
            guard let frame = try? await generator.image(at: CMTime(seconds: 1, preferredTimescale: 600)) else { return nil }
            return RenderedImage(cgImage: frame.image)
        }
    }

    /// Decodes an image at reduced size through ImageIO (never at full resolution).
    static func downsampledImage(at url: URL, maxPixelSize: CGFloat) -> RenderedImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options).map(RenderedImage.init)
    }

    // MARK: - Caching

    private func cacheKey(for item: MediaItem, pixelSize: CGFloat) -> String {
        let modified = item.modificationDate?.timeIntervalSince1970 ?? 0
        return "\(item.id)|\(item.size)|\(modified)|\(Int(pixelSize))"
    }

    private func store(_ image: RenderedImage, key: String) {
        let cost = image.cgImage.bytesPerRow * image.cgImage.height
        memoryCache.setObject(CacheEntry(image), forKey: key as NSString, cost: cost)
    }

    private func diskURL(for key: String) -> URL {
        let digest = SHA256.hash(data: Data(key.utf8)).hexString
        return diskCacheDirectory
            .appendingPathComponent(String(digest.prefix(2)), isDirectory: true)
            .appendingPathComponent(digest + ".jpg")
    }

    private func readDiskCache(key: String) -> RenderedImage? {
        let url = diskURL(for: key)
        guard FileManager.default.fileExists(atPath: url.path),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
        else { return nil }
        return RenderedImage(cgImage: image)
    }

    private func writeDiskCache(_ image: RenderedImage, key: String) {
        let url = diskURL(for: key)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image.cgImage, [kCGImageDestinationLossyCompressionQuality: 0.78] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }
}
