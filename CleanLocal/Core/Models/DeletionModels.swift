import Foundation

/// One entry in the deletion history. Created for every attempted removal, successful or not.
struct DeletionRecord: Identifiable, Codable, Hashable, Sendable {
    enum Status: String, Codable, Sendable {
        /// Moved to the Finder Trash. Recoverable until the user empties the Trash.
        case movedToTrash
        /// Deleted through PhotoKit. Lives in Photos › Recently Deleted for up to ~30 days.
        case removedFromPhotos
        /// The operation failed; the file was left untouched.
        case failed
        /// Removed immediately (only for rebuildable caches the user opted to delete directly,
        /// or items permanently removed from the Trash).
        case deletedPermanently
        /// Some files were removed; others were skipped (in use, locked, changed).
        case partial

        var title: String {
            switch self {
            case .movedToTrash: "Moved to Trash"
            case .removedFromPhotos: "Moved to Recently Deleted"
            case .failed: "Failed"
            case .deletedPermanently: "Deleted"
            case .partial: "Partially cleaned"
            }
        }

        var succeeded: Bool { self != .failed }
    }

    let id: UUID
    /// Groups records produced by a single user confirmation.
    let batchID: UUID
    let itemID: MediaItem.ID
    let filename: String
    /// Original path, or "Photos Library" for PhotoKit assets.
    let originalLocation: String
    let size: Int64
    let timestamp: Date
    let status: Status
    let errorDescription: String?
    /// Where the item landed inside the Trash, when the system reports it.
    let trashedPath: String?
    let wasPhotosAsset: Bool
    /// Cleanup category, for non-media cleanup.
    var category: String?
    /// Files removed, for folder cleanups.
    var itemCount: Int?
}

/// The outcome of one confirmed deletion request.
struct DeletionReport: Sendable, Identifiable {
    let id: UUID
    let records: [DeletionRecord]

    var succeededItemIDs: Set<MediaItem.ID> {
        Set(records.filter { $0.status.succeeded }.map(\.itemID))
    }

    var failures: [DeletionRecord] { records.filter { $0.status == .failed } }
    var successes: [DeletionRecord] { records.filter { $0.status.succeeded } }

    /// Bytes actually moved out of place. Only counts filesystem/PhotoKit operations that succeeded.
    var reclaimedBytes: Int64 { successes.reduce(0) { $0 + $1.size } }
}
