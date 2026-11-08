import CryptoKit
import Foundation

/// Streaming content hashing. Files are read in fixed-size chunks so even multi-gigabyte
/// videos never get loaded into memory at once.
enum FileHasher {
    static let defaultChunkSize = 1 << 20 // 1 MiB

    /// Full-content SHA-256 as a lowercase hex string. Honors task cancellation between chunks.
    static func sha256(of url: URL, chunkSize: Int = defaultChunkSize) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            if Task.isCancelled { throw CancellationError() }
            let chunk: Data? = try autoreleasepool { try handle.read(upToCount: chunkSize) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().hexString
    }

    /// Cheap fingerprint of the first and last `sampleSize` bytes plus the length.
    ///
    /// Used to split same-size duplicate candidates before paying for a full hash.
    /// Never used on its own to declare two files identical.
    static func edgeFingerprint(of url: URL, sampleSize: Int = 64 * 1024) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let length = try handle.seekToEnd()
        var hasher = SHA256()
        withUnsafeBytes(of: length.littleEndian) { hasher.update(bufferPointer: $0) }

        try handle.seek(toOffset: 0)
        if let head = try handle.read(upToCount: sampleSize) { hasher.update(data: head) }
        if length > UInt64(sampleSize) {
            try handle.seek(toOffset: length - UInt64(sampleSize))
            if let tail = try handle.read(upToCount: sampleSize) { hasher.update(data: tail) }
        }
        return hasher.finalize().hexString
    }
}

extension Digest {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
