import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CleanLocal

/// A unique temporary directory, removed on `cleanUp()` (permissions and locks are reset first).
/// Tests never touch real user folders.
final class TemporaryDirectory {
    let url: URL

    init(function: String = #function) throws {
        let name = "CleanLocalTests-" + function.filter { $0.isLetter || $0.isNumber } + "-" + UUID().uuidString.prefix(8)
        url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    @discardableResult
    func makeDirectory(_ relativePath: String) throws -> URL {
        let directory = url.appendingPathComponent(relativePath, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @discardableResult
    func writeData(_ data: Data, to relativePath: String) throws -> URL {
        let file = url.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: file)
        return file
    }

    func cleanUp() {
        if let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: []) {
            while let item = enumerator.nextObject() as? URL {
                try? FileManager.default.setAttributes([.immutable: false, .posixPermissions: 0o755], ofItemAtPath: item.path)
            }
        }
        try? FileManager.default.removeItem(at: url)
    }

    /// A policy that protects only paths under `protected/`, so the temp directory itself
    /// (which lives inside the app container's Library) is scannable in tests.
    var policy: ProtectedPathPolicy {
        ProtectedPathPolicy(protectedPrefixes: [url.appendingPathComponent("protected").path])
    }
}

/// Generates deterministic test images.
enum TestMedia {
    enum Pattern {
        /// Horizontal gradient with a dark disc on the left.
        case gradientWithDisc
        /// Checkerboard with the given cell size.
        case checkerboard(cell: Int)
        /// Diagonal stripes.
        case stripes
    }

    static func makeImage(width: Int = 640, height: Int = 480, pattern: Pattern) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, // swiftlint:disable:this force_unwrapping
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let w = CGFloat(width), h = CGFloat(height)
        switch pattern {
        case .gradientWithDisc:
            for x in 0..<width {
                let value = CGFloat(x) / w
                context.setFillColor(red: value, green: 0.4 + value * 0.4, blue: 1 - value, alpha: 1)
                context.fill(CGRect(x: CGFloat(x), y: 0, width: 1, height: h))
            }
            context.setFillColor(red: 0.05, green: 0.05, blue: 0.1, alpha: 1)
            context.fillEllipse(in: CGRect(x: w * 0.1, y: h * 0.2, width: w * 0.35, height: h * 0.55))
        case let .checkerboard(cell):
            for y in stride(from: 0, to: height, by: cell) {
                for x in stride(from: 0, to: width, by: cell) {
                    let dark = ((x / cell) + (y / cell)).isMultiple(of: 2)
                    context.setFillColor(gray: dark ? 0.1 : 0.9, alpha: 1)
                    context.fill(CGRect(x: x, y: y, width: cell, height: cell))
                }
            }
        case .stripes:
            context.setFillColor(gray: 0.95, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: w, height: h))
            context.setStrokeColor(gray: 0.1, alpha: 1)
            context.setLineWidth(w / 30)
            for offset in stride(from: -h, to: w, by: w / 8) {
                context.move(to: CGPoint(x: offset, y: 0))
                context.addLine(to: CGPoint(x: offset + h, y: h))
            }
            context.strokePath()
        }
        return context.makeImage()!
    }

    @discardableResult
    static func writeImage(
        _ image: CGImage,
        to url: URL,
        type: UTType = .png,
        properties: [CFString: Any] = [:]
    ) throws -> URL {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Downscales an image (simulating a resized/recompressed copy).
    static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}

/// Builds `MediaItem` values for pure-logic tests.
func makeItem(
    id: String = UUID().uuidString,
    path: String? = nil,
    filename: String? = nil,
    format: MediaFormat = .jpeg,
    size: Int64 = 1_000,
    created: Date? = Date(timeIntervalSince1970: 1_600_000_000),
    modified: Date? = Date(timeIntervalSince1970: 1_600_000_000),
    width: Int? = 4000,
    height: Int? = 3000,
    isScreenshot: Bool = false,
    locationID: UUID = UUID(),
    photos: Bool = false,
    contentHash: String? = nil,
    perceptualHash: UInt64? = nil,
    differenceHash: UInt64? = nil
) -> MediaItem {
    let fileExtension = format == .jpeg ? "jpg" : (format.fileExtensions.sorted().first ?? "jpg")
    let resolvedPath = photos ? nil : (path ?? "/Users/test/Pictures/\(id).\(fileExtension)")
    return MediaItem(
        id: photos ? MediaItem.photosID(forLocalIdentifier: id) : (resolvedPath ?? id),
        source: photos ? .photosLibrary : .fileSystem(locationID: locationID),
        path: resolvedPath,
        photosLocalIdentifier: photos ? id : nil,
        filename: filename ?? (resolvedPath.map { ($0 as NSString).lastPathComponent } ?? "\(id).jpg"),
        format: format,
        kind: format.kind,
        size: size,
        creationDate: created,
        modificationDate: modified,
        captureDate: nil,
        pixelWidth: width,
        pixelHeight: height,
        duration: format.kind == .video ? 12 : nil,
        isScreenshot: isScreenshot,
        discoveredAt: Date(timeIntervalSince1970: 1_700_000_000),
        lastScannedAt: Date(timeIntervalSince1970: 1_700_000_000),
        contentHash: contentHash,
        perceptualHash: perceptualHash,
        differenceHash: differenceHash
    )
}

/// Records every progress callback (thread-safe).
final class ProgressRecorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value] = []
    func record(_ value: Value) { lock.withLock { storage.append(value) } }
    var values: [Value] { lock.withLock { storage } }
}
