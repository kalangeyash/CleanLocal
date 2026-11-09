import Foundation

/// Owns CleanLocal's on-disk state, all stored locally in the app's Application Support
/// container. Nothing is synced or uploaded.
struct PersistenceController: Sendable {
    let baseURL: URL
    let locations: JSONFileStore<[ScanLocation]>
    let mediaIndex: JSONFileStore<[MediaItem]>
    let scanHistory: JSONFileStore<[ScanSession]>
    let deletionHistory: JSONFileStore<[DeletionRecord]>
    let accessGrants: JSONFileStore<AccessGrants>

    init(baseURL: URL) {
        self.baseURL = baseURL
        locations = JSONFileStore(fileURL: baseURL.appendingPathComponent("locations.json"), defaultValue: [])
        mediaIndex = JSONFileStore(fileURL: baseURL.appendingPathComponent("media-index.json"), defaultValue: [])
        scanHistory = JSONFileStore(fileURL: baseURL.appendingPathComponent("scan-history.json"), defaultValue: [])
        deletionHistory = JSONFileStore(fileURL: baseURL.appendingPathComponent("deletion-history.json"), defaultValue: [])
        accessGrants = JSONFileStore(fileURL: baseURL.appendingPathComponent("access-grants.json"), defaultValue: AccessGrants())
    }

    static func live() -> PersistenceController {
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return PersistenceController(baseURL: support.appendingPathComponent("CleanLocal", isDirectory: true))
    }

    /// Size of the persisted index files on disk.
    func storageFootprint() -> Int64 {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: baseURL, includingPropertiesForKeys: [.fileSizeKey]
        ) else { return 0 }
        return contents.reduce(Int64(0)) { total, url in
            total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
    }
}
