import AVFoundation
import Foundation
import ImageIO

/// Technical metadata read from a media file without decoding its pixels or frames.
struct MediaMetadata: Equatable, Sendable {
    var pixelWidth: Int?
    var pixelHeight: Int?
    var duration: TimeInterval?
    var captureDate: Date?
    var exifUserComment: String?
}

/// Reads dimensions, durations and capture dates using ImageIO and AVFoundation.
///
/// ImageIO's property API only parses headers, and AVFoundation's async `load` API
/// reads only the container atoms it needs, so this is cheap even for huge files.
/// Formats the frameworks cannot parse (e.g. some MKV/AVI files) yield empty metadata
/// instead of failing the scan.
struct MediaMetadataService: Sendable {
    func metadata(for url: URL, kind: MediaKind) async -> MediaMetadata {
        switch kind {
        case .image: imageMetadata(for: url)
        case .video: await videoMetadata(for: url)
        }
    }

    func imageMetadata(for url: URL) -> MediaMetadata {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any]
        else { return MediaMetadata() }

        var width = properties[kCGImagePropertyPixelWidth] as? Int
        var height = properties[kCGImagePropertyPixelHeight] as? Int
        // EXIF orientations 5–8 are rotated 90°: report the dimensions as displayed.
        if let orientation = properties[kCGImagePropertyOrientation] as? UInt32, (5...8).contains(orientation) {
            swap(&width, &height)
        }

        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)

        return MediaMetadata(
            pixelWidth: width,
            pixelHeight: height,
            duration: nil,
            captureDate: dateString.flatMap(Self.parseExifDate),
            exifUserComment: exif?[kCGImagePropertyExifUserComment] as? String
        )
    }

    func videoMetadata(for url: URL) async -> MediaMetadata {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        var result = MediaMetadata()

        if let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 {
            result.duration = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let (naturalSize, transform) = try? await track.load(.naturalSize, .preferredTransform) {
            let displayed = CGRect(origin: .zero, size: naturalSize).applying(transform)
            result.pixelWidth = Int(abs(displayed.width).rounded())
            result.pixelHeight = Int(abs(displayed.height).rounded())
        }
        if let creation = try? await asset.load(.creationDate),
           let date = try? await creation.load(.dateValue) {
            result.captureDate = date
        }
        return result
    }

    /// Parses EXIF dates ("yyyy:MM:dd HH:mm:ss") in the current time zone, as cameras record local time.
    static func parseExifDate(_ string: String) -> Date? {
        let numbers = string
            .split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" })
            .prefix(6)
            .compactMap { Int($0) }
        guard numbers.count == 6, numbers[0] > 1900, (1...12).contains(numbers[1]), (1...31).contains(numbers[2])
        else { return nil }
        var components = DateComponents()
        components.year = numbers[0]
        components.month = numbers[1]
        components.day = numbers[2]
        components.hour = numbers[3]
        components.minute = numbers[4]
        components.second = numbers[5]
        return Calendar(identifier: .gregorian).date(from: components)
    }
}
