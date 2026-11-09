import Foundation

/// How confident CleanLocal is that removing something is harmless.
enum SafetyLevel: Int, Codable, Comparable, CaseIterable, Sendable, Hashable {
    /// Verified disposable data (rebuildable caches, old logs) under defined conditions.
    case safe = 0
    /// May be unneeded, but could hold state or data the user wants to keep.
    case review = 1
    /// System data, credentials, user data, in-use or unclassifiable items. Never selectable.
    case protected = 2

    static func < (lhs: SafetyLevel, rhs: SafetyLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var title: String {
        switch self {
        case .safe: "Safe to Clean"
        case .review: "Review Before Cleaning"
        case .protected: "Protected"
        }
    }

    var shortTitle: String {
        switch self {
        case .safe: "Safe"
        case .review: "Review"
        case .protected: "Protected"
        }
    }

    var symbolName: String {
        switch self {
        case .safe: "checkmark.shield.fill"
        case .review: "eye.fill"
        case .protected: "lock.fill"
        }
    }
}

/// Sidebar-level grouping of cleanup categories.
enum CleanupGroup: String, CaseIterable, Codable, Sendable, Hashable, Identifiable {
    case systemJunk, applicationCache, temporaryFiles, browser, developer, leftovers, installers
    /// Individual files chosen in the Storage Analyzer, Large Files or Old Files.
    case userFiles

    var id: String { rawValue }

    var title: String {
        switch self {
        case .systemJunk: "System Junk"
        case .applicationCache: "Application Cache"
        case .temporaryFiles: "Temporary Files"
        case .browser: "Browser Cleanup"
        case .developer: "Developer Cleanup"
        case .leftovers: "Application Leftovers"
        case .installers: "Old Installers"
        case .userFiles: "Files"
        }
    }

    var symbolName: String {
        switch self {
        case .systemJunk: "gearshape.2.fill"
        case .applicationCache: "shippingbox.fill"
        case .temporaryFiles: "hourglass"
        case .browser: "globe"
        case .developer: "hammer.fill"
        case .leftovers: "app.dashed"
        case .installers: "opticaldiscdrive.fill"
        case .userFiles: "doc.fill"
        }
    }
}

/// What happens to approved items.
enum CleanupMethod: String, Codable, Sendable, Hashable {
    /// `FileManager.trashItem`: recoverable until the Trash is emptied. The default.
    case moveToTrash
    /// Immediate removal; only offered for verified, rebuildable caches and only when the
    /// user has opted in.
    case deletePermanently

    var title: String {
        switch self {
        case .moveToTrash: "Move to Trash"
        case .deletePermanently: "Delete immediately"
        }
    }
}

/// Which part of a candidate is removed.
enum CleanupScope: Hashable, Codable, Sendable {
    /// The file or folder itself.
    case item
    /// The folder's eligible top-level contents; the folder itself is kept.
    case contents
    /// Regular files older than the given number of days, anywhere inside the folder.
    /// Folders and newer files are kept.
    case filesOlderThan(days: Int)
}

/// A static description of one kind of cleanable data.
struct CleanupCategory: Identifiable, Hashable, Sendable {
    let id: String
    let group: CleanupGroup
    let title: String
    let symbolName: String
    /// What the data is.
    let summary: String
    /// Why it's classified the way it is, and under which conditions.
    let safetyNote: String
    /// What the user may notice after cleaning.
    let impact: String
    let defaultSafety: SafetyLevel
    /// Whether immediate deletion is permitted when the user opts in.
    let allowsImmediateDeletion: Bool
    /// Cleaning requires the owning application to be closed.
    let requiresOwnerClosed: Bool
}

/// The application an item belongs to.
struct AppOwner: Hashable, Codable, Sendable {
    let bundleID: String
    let name: String
    let isInstalled: Bool
    let isRunning: Bool
}

/// One item found by a cleanup scan.
struct CleanupCandidate: Identifiable, Hashable, Sendable {
    /// Absolute path (unique per scan).
    let id: String
    let url: URL
    let categoryID: String
    var displayName: String
    var detail: String?
    var scope: CleanupScope
    var safety: SafetyLevel
    /// Plain-language reasons behind the classification.
    var reasons: [String]
    var owner: AppOwner?
    var isDirectory: Bool
    /// Size of the eligible portion only (respecting `scope`).
    var size: DirectorySize
    /// Identity at scan time; cleanup is refused if the item was replaced.
    var identity: FileIdentity
    /// The authorized root the item was found under.
    var rootPath: String

    var isSelectable: Bool { safety != .protected && size.fileCount + size.directoryCount > 0 }
}

/// A location the scan could not read, with the reason.
struct AccessIssue: Identifiable, Hashable, Sendable {
    var id: String { path }
    let path: String
    let reason: String
}

struct CleanupScanResult: Sendable {
    var candidates: [CleanupCandidate]
    var issues: [AccessIssue]
    var scannedAt: Date
    var duration: TimeInterval
}

struct CleanupScanProgress: Sendable, Equatable {
    var categoryTitle = ""
    var completedCategories = 0
    var totalCategories = 0
    var itemsFound = 0
    var bytesFound: Int64 = 0

    var fraction: Double {
        totalCategories == 0 ? 0 : Double(completedCategories) / Double(totalCategories)
    }
}

/// Per-candidate outcome of a cleanup run.
struct CleanupItemResult: Identifiable, Sendable {
    var id: String { candidate.id }
    let candidate: CleanupCandidate
    let method: CleanupMethod
    var removedFiles = 0
    var removedBytes: Int64 = 0
    /// Bytes actually freed now (permanent deletion only).
    var freedBytes: Int64 = 0
    var skippedFiles = 0
    var errors: [String] = []
    /// Where removed entries landed in the Trash (for "Free space now").
    var trashedPaths: [String] = []

    var status: DeletionRecord.Status {
        if removedFiles == 0 { return .failed }
        if skippedFiles > 0 || !errors.isEmpty { return .partial }
        return method == .deletePermanently ? .deletedPermanently : .movedToTrash
    }
}

struct CleanupReport: Identifiable, Sendable {
    let id: UUID
    let results: [CleanupItemResult]
    let finishedAt: Date

    var movedToTrashBytes: Int64 {
        results.filter { $0.method == .moveToTrash }.reduce(0) { $0 + $1.removedBytes }
    }
    var freedBytes: Int64 { results.reduce(0) { $0 + $1.freedBytes } }
    var removedFiles: Int { results.reduce(0) { $0 + $1.removedFiles } }
    var failures: [CleanupItemResult] { results.filter { $0.status == .failed || $0.status == .partial } }
    var trashedPaths: [String] { results.flatMap(\.trashedPaths) }
}
