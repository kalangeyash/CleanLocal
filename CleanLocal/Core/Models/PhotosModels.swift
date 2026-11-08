import Foundation

/// CleanLocal's view of the Photos privacy authorization state.
enum PhotosAuthorization: Equatable, Sendable {
    case notDetermined
    case authorized
    /// The user granted access to a subset of photos only.
    case limited
    case denied
    case restricted

    var canRead: Bool { self == .authorized || self == .limited }
}

/// A Photos album or smart album.
struct PhotoAlbum: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let assetCount: Int
    let isSmartAlbum: Bool
}
