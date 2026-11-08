import Foundation

/// Storage figures computed from real filesystem data and the scanned index.
struct StorageAnalyticsService: Sendable {
    private static let volumeKeys: Set<URLResourceKey> = [
        .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey,
        .volumeNameKey, .volumeIsRemovableKey, .volumeURLKey,
    ]

    /// Capacity of the volume containing `url`.
    func volumeCapacity(for url: URL) -> VolumeCapacity? {
        guard let values = try? url.resourceValues(forKeys: Self.volumeKeys),
              let total = values.volumeTotalCapacity else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage
            ?? values.volumeAvailableCapacity.map(Int64.init) ?? 0
        return VolumeCapacity(
            volumePath: values.volume?.path ?? url.path,
            name: values.volumeName ?? "Disk",
            totalBytes: Int64(total),
            availableBytes: available,
            isRemovable: values.volumeIsRemovable ?? false
        )
    }

    /// The startup data volume (the app container lives on it, which keeps this sandbox-safe).
    func startupVolume() -> VolumeCapacity? {
        volumeCapacity(for: URL(fileURLWithPath: NSHomeDirectory()))
    }

    /// Distinct volumes for the given folders, plus the startup volume first.
    func volumes(for urls: [URL]) -> [VolumeCapacity] {
        var seen = Set<String>()
        var result: [VolumeCapacity] = []
        for capacity in ([startupVolume()] + urls.map(volumeCapacity(for:))).compactMap({ $0 })
        where seen.insert(capacity.volumePath).inserted {
            result.append(capacity)
        }
        return result
    }

    static func breakdown(of items: [MediaItem]) -> MediaBreakdown {
        var counts: [MediaCategory: (count: Int, bytes: Int64)] = [:]
        var photoCount = 0, videoCount = 0, totalBytes: Int64 = 0
        for item in items {
            counts[item.category, default: (0, 0)].count += 1
            counts[item.category, default: (0, 0)].bytes += item.size
            totalBytes += item.size
            if item.kind == .video { videoCount += 1 } else { photoCount += 1 }
        }
        return MediaBreakdown(
            entries: MediaCategory.allCases.map { category in
                MediaBreakdown.Entry(category: category, count: counts[category]?.count ?? 0, bytes: counts[category]?.bytes ?? 0)
            },
            totalCount: items.count,
            totalBytes: totalBytes,
            photoCount: photoCount,
            videoCount: videoCount
        )
    }

    static func totalSize<S: Sequence>(of items: S) -> Int64 where S.Element == MediaItem {
        items.reduce(0) { $0 + $1.size }
    }

    /// Bytes reclaimable by removing every non-keeper copy in exact duplicate groups.
    /// Items are counted once even if they appear in several groups.
    static func reclaimableBytes(in groups: [DuplicateGroup]) -> Int64 {
        var counted = Set<MediaItem.ID>()
        var total: Int64 = 0
        for group in groups {
            for item in group.items where item.id != group.suggestedKeeperID && counted.insert(item.id).inserted {
                total += item.size
            }
        }
        return total
    }
}
