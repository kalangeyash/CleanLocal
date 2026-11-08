import Foundation
import OSLog

/// A small, crash-safe, versioned JSON document store.
///
/// * Writes are atomic (temp file + rename), so a crash never leaves a half-written file.
/// * A corrupt or incompatible file is moved aside (not deleted) and the default value is
///   returned, so the app always launches.
/// * Being an actor, concurrent saves from different tasks are serialized.
actor JSONFileStore<Value: Codable & Sendable> {
    private struct Envelope: Codable {
        let schemaVersion: Int
        let savedAt: Date
        let value: Value
    }

    let fileURL: URL
    private let schemaVersion: Int
    private let defaultValue: Value
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(fileURL: URL, schemaVersion: Int = 1, defaultValue: Value) {
        self.fileURL = fileURL
        self.schemaVersion = schemaVersion
        self.defaultValue = defaultValue
        encoder.dateEncodingStrategy = .secondsSince1970
        decoder.dateDecodingStrategy = .secondsSince1970
    }

    func load() -> Value {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return defaultValue }
        do {
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            let envelope = try decoder.decode(Envelope.self, from: data)
            guard envelope.schemaVersion == schemaVersion else {
                Logger.persistence.notice("Schema mismatch for \(self.fileURL.lastPathComponent, privacy: .public); starting fresh")
                quarantineCurrentFile(reason: "schema-\(envelope.schemaVersion)")
                return defaultValue
            }
            return envelope.value
        } catch {
            Logger.persistence.error("Failed to read \(self.fileURL.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            quarantineCurrentFile(reason: "corrupt")
            return defaultValue
        }
    }

    func save(_ value: Value) throws {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try encoder.encode(Envelope(schemaVersion: schemaVersion, savedAt: .now, value: value))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            throw CleanLocalError.persistenceFailed(reason: error.localizedDescription)
        }
    }

    func reset() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            try FileManager.default.removeItem(at: fileURL)
        } catch {
            throw CleanLocalError.persistenceFailed(reason: error.localizedDescription)
        }
    }

    private func quarantineCurrentFile(reason: String) {
        let stamp = Int(Date.now.timeIntervalSince1970)
        let destination = fileURL.deletingPathExtension()
            .appendingPathExtension("\(reason)-\(stamp).json")
        try? FileManager.default.moveItem(at: fileURL, to: destination)
    }
}
