import Foundation

/// A folder (or volume) the user explicitly authorized CleanLocal to scan.
struct ScanLocation: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var displayName: String
    /// Path at the time the bookmark was created or last refreshed. Display only;
    /// the bookmark is the source of truth for access.
    var path: String
    /// Security-scoped bookmark data granting persistent access.
    var bookmarkData: Data
    var isRemovableVolume: Bool
    var addedAt: Date
    var lastScannedAt: Date?
    var isEnabled: Bool

    init(
        id: UUID = UUID(),
        displayName: String,
        path: String,
        bookmarkData: Data,
        isRemovableVolume: Bool = false,
        addedAt: Date = .now,
        lastScannedAt: Date? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.path = path
        self.bookmarkData = bookmarkData
        self.isRemovableVolume = isRemovableVolume
        self.addedAt = addedAt
        self.lastScannedAt = lastScannedAt
        self.isEnabled = isEnabled
    }
}

/// Runtime availability of a ``ScanLocation`` (not persisted).
enum LocationStatus: Equatable, Sendable {
    case available
    /// The folder was moved/renamed or the drive is disconnected.
    case unavailable(reason: String)
}

/// A directory root handed to the scanner, with access already started.
struct ScanRoot: Sendable, Hashable {
    let locationID: UUID
    let name: String
    let url: URL
}

/// A problem encountered while scanning that did not stop the scan.
struct ScanIssue: Codable, Hashable, Sendable, Identifiable {
    var id: String { path + "|" + reason }
    let path: String
    let reason: String
}

/// Live progress for the scanning UI.
struct ScanProgress: Equatable, Sendable {
    enum Phase: String, Equatable, Sendable {
        case preparing = "Preparing"
        case discovering = "Discovering files"
        case readingMetadata = "Reading metadata"
        case photosLibrary = "Reading Photos library"
        case analyzingDuplicates = "Finding duplicates"
        case finalizing = "Finishing up"
    }

    var phase: Phase = .preparing
    var currentLocationName: String = ""
    var currentPath: String = ""
    var filesVisited: Int = 0
    var mediaFound: Int = 0
    var metadataTotal: Int = 0
    var metadataProcessed: Int = 0
    var issuesCount: Int = 0

    /// Fraction for determinate phases, `nil` while discovering (unknown total).
    var fractionCompleted: Double? {
        guard phase == .readingMetadata, metadataTotal > 0 else { return nil }
        return Double(metadataProcessed) / Double(metadataTotal)
    }
}

/// Output of one scanner run.
struct ScanResult: Sendable {
    /// Every media item found under the scanned roots (reused + newly read).
    var items: [MediaItem]
    var issues: [ScanIssue]
    var newItemCount: Int
    var reusedItemCount: Int
    var removedItemIDs: Set<MediaItem.ID>
    var scannedLocationIDs: Set<UUID>
    var startedAt: Date
    var finishedAt: Date
}

/// Persisted summary of a completed (or cancelled) scan, shown in history.
struct ScanSession: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var startedAt: Date
    var finishedAt: Date
    var locationNames: [String]
    var includedPhotosLibrary: Bool
    var mediaCount: Int
    var totalBytes: Int64
    var newItemCount: Int
    var removedItemCount: Int
    var issueCount: Int
    var wasCancelled: Bool

    var duration: TimeInterval { finishedAt.timeIntervalSince(startedAt) }
}
