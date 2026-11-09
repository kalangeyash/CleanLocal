import Foundation

/// A set of media items that are byte-identical (`exact`) or visually alike (`similar`).
struct DuplicateGroup: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable, Hashable {
        /// Byte-identical (SHA-256 verified).
        case exact
        /// Visually alike; never auto-selected.
        case similar
        /// Photos assets whose originals are only in iCloud: same dimensions, capture time,
        /// duration and appearance, but bytes weren't compared. Never auto-selected.
        case probable
    }

    let id: String
    let kind: Kind
    var items: [MediaItem]
    /// The copy CleanLocal recommends keeping. Never auto-selected for deletion.
    var suggestedKeeperID: MediaItem.ID
    /// Average similarity between members in `0...1` (1 for exact duplicates).
    var similarity: Double

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }

    /// Bytes freed if every copy except the suggested keeper were moved to the Trash.
    /// Clone-aware: copies that are APFS clones of the keeper free nothing.
    var reclaimableBytes: Int64 {
        let keeperClone = keeper?.cloneID
        return items.filter { $0.id != suggestedKeeperID }.reduce(0) { total, item in
            if let clone = item.cloneID, clone == keeperClone { return total }
            return total + item.effectiveReclaimableSize
        }
    }

    /// Some copies share disk space (APFS clones), so the visible size overstates savings.
    var involvesClones: Bool {
        let clones = items.compactMap(\.cloneID)
        return Set(clones).count < clones.count || items.contains(where: \.isSharedOnDisk)
    }

    var keeper: MediaItem? { items.first { $0.id == suggestedKeeperID } }
}

/// Aggregated per-category storage figures.
struct MediaBreakdown: Equatable, Sendable {
    struct Entry: Identifiable, Equatable, Sendable {
        var id: MediaCategory { category }
        let category: MediaCategory
        var count: Int
        var bytes: Int64
    }

    var entries: [Entry]
    var totalCount: Int
    var totalBytes: Int64
    var photoCount: Int
    var videoCount: Int

    static let empty = MediaBreakdown(
        entries: MediaCategory.allCases.map { Entry(category: $0, count: 0, bytes: 0) },
        totalCount: 0, totalBytes: 0, photoCount: 0, videoCount: 0
    )

    func entry(for category: MediaCategory) -> Entry {
        entries.first { $0.category == category } ?? Entry(category: category, count: 0, bytes: 0)
    }
}

/// Capacity of a mounted volume.
struct VolumeCapacity: Equatable, Sendable, Identifiable {
    var id: String { volumePath }
    let volumePath: String
    let name: String
    let totalBytes: Int64
    /// Space available for important (user-initiated) data, as the system reports it.
    let availableBytes: Int64
    let isRemovable: Bool

    var usedBytes: Int64 { max(0, totalBytes - availableBytes) }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}
