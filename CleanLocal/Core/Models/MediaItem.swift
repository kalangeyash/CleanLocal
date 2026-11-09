import Foundation

/// Where a media item lives. The distinction drives which deletion workflow is legal.
enum MediaSource: Hashable, Codable, Sendable {
    /// A regular file inside a user-authorized scan location.
    case fileSystem(locationID: UUID)
    /// An asset managed by the Apple Photos library. Only PhotoKit may modify it.
    case photosLibrary
}

/// A single indexed photo or video.
///
/// Items are value types so they can move freely between the scanner, analysis
/// services and the UI without shared mutable state.
struct MediaItem: Identifiable, Hashable, Codable, Sendable {
    typealias ID = String

    let id: ID
    var source: MediaSource
    /// Absolute POSIX path. `nil` for Photos library assets.
    var path: String?
    /// PhotoKit local identifier. `nil` for regular files.
    var photosLocalIdentifier: String?
    var filename: String
    var format: MediaFormat?
    var kind: MediaKind
    /// Logical file size in bytes (what Finder reports as "Size").
    var size: Int64
    var creationDate: Date?
    var modificationDate: Date?
    /// Capture date from EXIF / QuickTime metadata when available.
    var captureDate: Date?
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: TimeInterval?
    var isScreenshot: Bool
    /// When CleanLocal first indexed this item.
    var discoveredAt: Date
    /// When this item was last confirmed present by a scan.
    var lastScannedAt: Date
    /// Cached SHA-256 of the full content (hex). Invalidated when size/mtime change.
    var contentHash: String?
    /// Cached 64-bit perceptual (DCT) hash for similarity detection.
    var perceptualHash: UInt64?
    /// Cached 64-bit difference hash used as a secondary similarity check.
    var differenceHash: UInt64?
    /// What deleting this file actually frees: its APFS private size, or 0 when it's hard-linked.
    /// `nil` when unknown (Photos assets, other filesystems).
    var reclaimableSize: Int64? = nil
    /// APFS clone identifier; files cloned from one another share it.
    var cloneID: UInt64? = nil
}

extension MediaItem {
    static func fileID(forPath path: String) -> ID { path }
    static func photosID(forLocalIdentifier identifier: String) -> ID { "photos:" + identifier }

    var url: URL? { path.map { URL(fileURLWithPath: $0) } }

    var isPhotosAsset: Bool { source == .photosLibrary }

    /// Space freed by removing this item, falling back to the logical size.
    var effectiveReclaimableSize: Int64 { reclaimableSize ?? size }

    /// PhotoKit can't always report an asset's size (for example, iCloud-only originals).
    var hasKnownSize: Bool { size > 0 || !isPhotosAsset }

    /// Size for display: "Unknown size" rather than a misleading "0 KB".
    var displaySize: String { hasKnownSize ? size.formattedBytes : "Unknown size" }

    /// The item shares disk blocks with a clone, so deleting it frees less than its size.
    var isSharedOnDisk: Bool {
        guard let reclaimableSize else { return false }
        return reclaimableSize < size / 2
    }

    var locationID: UUID? {
        if case let .fileSystem(locationID) = source { return locationID }
        return nil
    }

    var category: MediaCategory {
        if isScreenshot { return .screenshots }
        if kind == .video { return .videos }
        if let format, format.isGraphic { return .other }
        return .photos
    }

    /// The most meaningful date for "how old is this": capture, then creation, then modification.
    var effectiveDate: Date {
        captureDate ?? creationDate ?? modificationDate ?? discoveredAt
    }

    var directoryPath: String? {
        path.map { ($0 as NSString).deletingLastPathComponent }
    }

    /// Short, human readable location ("~/Pictures/Trips" or "Photos Library").
    var locationDescription: String {
        guard let directoryPath else { return "Photos Library" }
        return UserDirectories.abbreviate(path: directoryPath)
    }

    var pixelCount: Int { (pixelWidth ?? 0) * (pixelHeight ?? 0) }

    var dimensionsDescription: String? {
        guard let pixelWidth, let pixelHeight, pixelWidth > 0, pixelHeight > 0 else { return nil }
        return "\(pixelWidth) × \(pixelHeight)"
    }

    var typeDescription: String {
        format?.shortName ?? kind.title
    }

    /// Whether cached hashes are still valid compared to a fresh observation of the same file.
    func hasSameContentSignature(size otherSize: Int64, modificationDate otherDate: Date?) -> Bool {
        guard size == otherSize else { return false }
        switch (modificationDate, otherDate) {
        case let (lhs?, rhs?): return abs(lhs.timeIntervalSince(rhs)) < 1
        case (nil, nil): return true
        default: return false
        }
    }
}
