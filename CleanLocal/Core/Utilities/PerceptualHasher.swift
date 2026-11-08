import CoreGraphics
import Foundation
import ImageIO

/// Perceptual image fingerprints for near-duplicate detection.
///
/// * **pHash** – 32×32 grayscale → 2D DCT → top-left 8×8 low frequencies (DC excluded)
///   compared against their median. Robust to resizing, recompression and small edits.
/// * **dHash** – 9×8 grayscale, one bit per horizontal gradient. Cheap secondary check
///   that reduces false positives from pHash alone.
///
/// Images are decoded through ImageIO's thumbnailing path, so a 50-megapixel photo is
/// never fully decoded just to be hashed.
enum PerceptualHasher {
    struct Hashes: Hashable, Sendable {
        let perceptual: UInt64
        let difference: UInt64
    }

    static let thumbnailPixelSize = 128

    static func hashes(forImageAt url: URL) -> Hashes? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: false,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailPixelSize,
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return hashes(for: image)
    }

    static func hashes(for image: CGImage) -> Hashes? {
        guard let dctPixels = grayscalePixels(of: image, width: 32, height: 32),
              let gradientPixels = grayscalePixels(of: image, width: 9, height: 8) else { return nil }
        return Hashes(perceptual: perceptualHash(pixels32: dctPixels), difference: differenceHash(pixels9x8: gradientPixels))
    }

    /// Number of differing bits between two 64-bit hashes (0 = identical, 64 = opposite).
    static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// Converts a user-facing similarity (0.5…1.0) into a maximum Hamming distance.
    static func maximumDistance(forSimilarity similarity: Double) -> Int {
        let clamped = min(max(similarity, 0.5), 1.0)
        return Int(((1 - clamped) * 64).rounded())
    }

    static func similarity(forDistance distance: Int) -> Double {
        1 - Double(distance) / 64
    }

    // MARK: - Internals

    static func grayscalePixels(of image: CGImage, width: Int, height: Int) -> [Float]? {
        var buffer = [UInt8](repeating: 0, count: width * height)
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw in
            guard let context = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            // Fill white first so transparent PNGs hash consistently.
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        return buffer.map(Float.init)
    }

    private static let dctSize = 32
    private static let lowFrequencySize = 8

    /// cos((2x + 1) u π / 2N) for u in 0..<8, x in 0..<32.
    private static let cosineTable: [Float] = {
        var table = [Float](repeating: 0, count: lowFrequencySize * dctSize)
        for u in 0..<lowFrequencySize {
            for x in 0..<dctSize {
                table[u * dctSize + x] = Float(cos(Double(2 * x + 1) * Double(u) * .pi / Double(2 * dctSize)))
            }
        }
        return table
    }()

    static func perceptualHash(pixels32 pixels: [Float]) -> UInt64 {
        precondition(pixels.count == dctSize * dctSize, "pHash expects a 32×32 image")
        let n = dctSize, k = lowFrequencySize

        // Separable DCT restricted to the 8 lowest frequencies on each axis.
        var rowPass = [Float](repeating: 0, count: n * k) // [y][u]
        for y in 0..<n {
            for u in 0..<k {
                var sum: Float = 0
                for x in 0..<n { sum += pixels[y * n + x] * cosineTable[u * n + x] }
                rowPass[y * k + u] = sum
            }
        }
        var coefficients = [Float](repeating: 0, count: k * k) // [v][u]
        for v in 0..<k {
            for u in 0..<k {
                var sum: Float = 0
                for y in 0..<n { sum += rowPass[y * k + u] * cosineTable[v * n + y] }
                coefficients[v * k + u] = sum
            }
        }

        // Exclude the DC term from the median: it only encodes overall brightness.
        let acTerms = Array(coefficients.dropFirst())
        let median = acTerms.sorted()[acTerms.count / 2]
        var hash: UInt64 = 0
        for (index, value) in coefficients.enumerated() where index > 0 && value > median {
            hash |= 1 << UInt64(index)
        }
        return hash
    }

    static func differenceHash(pixels9x8 pixels: [Float]) -> UInt64 {
        precondition(pixels.count == 72, "dHash expects a 9×8 image")
        var hash: UInt64 = 0
        var bit: UInt64 = 0
        for y in 0..<8 {
            for x in 0..<8 {
                if pixels[y * 9 + x] < pixels[y * 9 + x + 1] { hash |= 1 << bit }
                bit += 1
            }
        }
        return hash
    }
}
