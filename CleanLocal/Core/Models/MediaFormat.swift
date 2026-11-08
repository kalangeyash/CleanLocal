import Foundation

/// The broad kind of a media item.
enum MediaKind: String, Codable, Sendable, CaseIterable, Hashable {
    case image
    case video

    var title: String {
        switch self {
        case .image: "Photo"
        case .video: "Video"
        }
    }
}

/// User-facing storage categories used by the dashboard and analytics.
enum MediaCategory: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case photos
    case videos
    case screenshots
    case other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .photos: "Photos"
        case .videos: "Videos"
        case .screenshots: "Screenshots"
        case .other: "Other Media"
        }
    }

    var symbolName: String {
        switch self {
        case .photos: "photo.fill"
        case .videos: "film.fill"
        case .screenshots: "camera.viewfinder"
        case .other: "square.stack.3d.up.fill"
        }
    }
}

/// Every file format CleanLocal recognizes, grouped the way users think about them.
///
/// Classification is by file extension (cheap, no I/O). Metadata is read later by
/// ``MediaMetadataService``; formats the system frameworks cannot decode still get
/// indexed with size and dates so they remain visible to the user.
enum MediaFormat: String, CaseIterable, Codable, Sendable, Identifiable, Hashable {
    case jpeg
    case heic
    case png
    case raw
    case gif
    case tiff
    case bmp
    case webp
    case mp4
    case mov
    case m4v
    case avi
    case mkv
    case otherVideo

    var id: String { rawValue }

    var kind: MediaKind {
        switch self {
        case .mp4, .mov, .m4v, .avi, .mkv, .otherVideo: .video
        default: .image
        }
    }

    /// Graphics formats (as opposed to camera photos) are reported as "Other Media".
    var isGraphic: Bool {
        switch self {
        case .gif, .tiff, .bmp, .webp: true
        default: false
        }
    }

    var displayName: String {
        switch self {
        case .jpeg: "JPEG"
        case .heic: "HEIC / HEIF"
        case .png: "PNG"
        case .raw: "RAW (DNG, CR2, NEF, ARW…)"
        case .gif: "GIF"
        case .tiff: "TIFF"
        case .bmp: "BMP"
        case .webp: "WebP"
        case .mp4: "MP4"
        case .mov: "QuickTime (MOV)"
        case .m4v: "M4V"
        case .avi: "AVI"
        case .mkv: "Matroska (MKV)"
        case .otherVideo: "Other video (3GP, MTS, MPEG, WebM…)"
        }
    }

    var shortName: String {
        switch self {
        case .heic: "HEIC"
        case .raw: "RAW"
        case .mov: "MOV"
        case .mkv: "MKV"
        case .otherVideo: "Video"
        default: displayName
        }
    }

    var fileExtensions: Set<String> {
        switch self {
        case .jpeg: ["jpg", "jpeg", "jpe", "jfif"]
        case .heic: ["heic", "heif", "hif"]
        case .png: ["png"]
        case .raw: ["dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "orf", "rw2",
                    "raf", "pef", "srw", "3fr", "erf", "kdc", "mos", "mrw", "x3f", "rwl", "iiq"]
        case .gif: ["gif"]
        case .tiff: ["tif", "tiff"]
        case .bmp: ["bmp"]
        case .webp: ["webp"]
        case .mp4: ["mp4"]
        case .mov: ["mov", "qt"]
        case .m4v: ["m4v"]
        case .avi: ["avi"]
        case .mkv: ["mkv"]
        // `.ts` is deliberately excluded: it collides with TypeScript source files.
        case .otherVideo: ["3gp", "3g2", "mts", "m2ts", "mpg", "mpeg", "m2v", "wmv", "webm", "flv", "ogv"]
        }
    }

    private static let extensionLookup: [String: MediaFormat] = {
        var lookup: [String: MediaFormat] = [:]
        for format in MediaFormat.allCases {
            for fileExtension in format.fileExtensions {
                lookup[fileExtension] = format
            }
        }
        return lookup
    }()

    /// Returns the format for a file extension (case-insensitive), or `nil` for non-media files.
    static func from(fileExtension: String) -> MediaFormat? {
        extensionLookup[fileExtension.lowercased()]
    }

    static let imageFormats = allCases.filter { $0.kind == .image }
    static let videoFormats = allCases.filter { $0.kind == .video }
}
