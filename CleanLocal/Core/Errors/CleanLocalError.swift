import Foundation

/// Typed errors surfaced by CleanLocal services. Every case has a user-presentable message.
enum CleanLocalError: LocalizedError, Equatable, Sendable {
    // Permissions & locations
    case bookmarkCreationFailed(path: String, reason: String)
    case bookmarkResolutionFailed(reason: String)
    case accessDenied(path: String)
    case locationAlreadyAdded(path: String)
    case scanAlreadyRunning
    case noLocationsToScan

    // Safety checks
    case protectedLocation(path: String)
    case outsideAuthorizedLocations(path: String)
    case symbolicLinkRefused(path: String)
    case notARegularFile(path: String)
    case fileChangedSinceScan(path: String)

    // Filesystem failures
    case fileNotFound(path: String)
    case fileLocked(path: String)
    case fileInUse(path: String)
    case permissionDenied(path: String)
    case readOnlyVolume(path: String)
    case volumeUnavailable(path: String)
    case trashFailed(path: String, reason: String)

    // Photos
    case photosAuthorizationDenied
    case photosAssetUnavailable(identifier: String)
    case photosChangeFailed(reason: String)
    case photosDeletionCancelled

    // Persistence
    case persistenceFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case let .bookmarkCreationFailed(path, reason):
            "CleanLocal couldn’t remember access to “\(path)”: \(reason)"
        case let .bookmarkResolutionFailed(reason):
            "A saved folder can no longer be accessed: \(reason)"
        case let .accessDenied(path):
            "macOS denied access to “\(path)”. Re-add the folder to grant access again."
        case let .locationAlreadyAdded(path):
            "“\(path)” is already a scan location."
        case .scanAlreadyRunning:
            "A scan is already running."
        case .noLocationsToScan:
            "Add a folder or connect your Photos library before scanning."
        case let .protectedLocation(path):
            "“\(path)” is in a protected system or application location. CleanLocal never modifies these."
        case let .outsideAuthorizedLocations(path):
            "“\(path)” is outside the folders you authorized."
        case let .symbolicLinkRefused(path):
            "“\(path)” is a symbolic link. CleanLocal only removes real files."
        case let .notARegularFile(path):
            "“\(path)” is not a regular file."
        case let .fileChangedSinceScan(path):
            "“\(path)” changed since it was scanned. Rescan before removing it."
        case let .fileNotFound(path):
            "“\(path)” no longer exists."
        case let .fileLocked(path):
            "“\(path)” is locked. Unlock it in Finder’s Get Info window first."
        case let .fileInUse(path):
            "“\(path)” is in use by another application."
        case let .permissionDenied(path):
            "You don’t have permission to move “\(path)” to the Trash."
        case let .readOnlyVolume(path):
            "“\(path)” is on a read-only volume."
        case let .volumeUnavailable(path):
            "The drive containing “\(path)” is no longer connected."
        case let .trashFailed(path, reason):
            "Couldn’t move “\(path)” to the Trash: \(reason)"
        case .photosAuthorizationDenied:
            "CleanLocal doesn’t have access to your Photos library. You can grant it in System Settings › Privacy & Security › Photos."
        case let .photosAssetUnavailable(identifier):
            "The Photos item \(identifier) is no longer available."
        case let .photosChangeFailed(reason):
            "Photos couldn’t complete the change: \(reason)"
        case .photosDeletionCancelled:
            "Deletion was cancelled in the Photos confirmation dialog."
        case let .persistenceFailed(reason):
            "CleanLocal couldn’t save its data: \(reason)"
        }
    }
}
