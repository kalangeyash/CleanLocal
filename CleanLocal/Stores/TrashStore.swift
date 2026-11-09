import Foundation
import Observation

/// Trash contents and emptying, for the Trash Manager and "Free space now".
@MainActor
@Observable
final class TrashStore {
    private(set) var entries: [TrashEntry] = []
    private(set) var issues: [AccessIssue] = []
    private(set) var isLoading = false
    private(set) var isEmptying = false
    var selection = Set<TrashEntry.ID>()
    var lastResult: FreeSpaceResult?

    @ObservationIgnored private let access: AccessStore
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let deletion: DeletionStore
    @ObservationIgnored private let service: TrashService

    init(access: AccessStore, library: LibraryStore, deletion: DeletionStore, service: TrashService = TrashService()) {
        self.access = access
        self.library = library
        self.deletion = deletion
        self.service = service
    }

    var totalSize: DirectorySize { entries.reduce(DirectorySize()) { $0 + $1.size } }

    var selectedEntries: [TrashEntry] { entries.filter { selection.contains($0.id) } }

    private var trashFolders: [URL] {
        let volumes = library.locations.compactMap { location -> URL? in
            let components = location.path.split(separator: "/")
            guard location.path.hasPrefix("/Volumes/"), components.count >= 2 else { return nil }
            return URL(fileURLWithPath: "/" + components.prefix(2).joined(separator: "/"))
        }
        return TrashService.trashFolders(homeTrash: access.trashURL, volumeRoots: volumes)
    }

    func refresh() async {
        guard !trashFolders.isEmpty else {
            entries = []
            return
        }
        isLoading = true
        let originals = Dictionary(deletion.history.compactMap { record in record.trashedPath.map { ($0, record.originalLocation) } },
                                   uniquingKeysWith: { first, _ in first })
        let (entries, issues) = await service.entries(in: trashFolders, originalPaths: originals)
        self.entries = entries
        self.issues = issues
        selection.formIntersection(Set(entries.map(\.id)))
        isLoading = false
    }

    /// Permanently removes entries. Callers must have confirmed with the user.
    func permanentlyDelete(_ targets: [TrashEntry]) async {
        guard !targets.isEmpty else { return }
        isEmptying = true
        let results = await service.permanentlyDelete(targets)
        record(results, names: Dictionary(uniqueKeysWithValues: targets.map { ($0.url.path, $0.name) }))
        lastResult = FreeSpaceResult(
            freedBytes: results.reduce(0) { $0 + $1.freedBytes },
            failures: results.compactMap { result in result.error.map { "\((result.path as NSString).lastPathComponent): \($0)" } },
            needsTrashAccess: false
        )
        isEmptying = false
        await refresh()
    }

    /// "Free space now": permanently removes items CleanLocal itself just moved to the Trash.
    func deleteTrashedItems(_ paths: [String]) async -> FreeSpaceResult {
        guard !paths.isEmpty else { return FreeSpaceResult(freedBytes: 0, failures: [], needsTrashAccess: false) }
        let results = await service.deleteTrashedItems(paths)
        record(results, names: [:])
        let failures = results.compactMap(\.error)
        let denied = results.contains { $0.error?.contains("permission") == true }
        if !entries.isEmpty { await refresh() }
        return FreeSpaceResult(freedBytes: results.reduce(0) { $0 + $1.freedBytes }, failures: failures,
                               needsTrashAccess: denied && !access.hasTrashAccess)
    }

    private func record(_ results: [TrashRemovalResult], names: [String: String]) {
        let batch = UUID()
        deletion.record(results.map { result in
            DeletionRecord(
                id: UUID(), batchID: batch, itemID: result.path,
                filename: names[result.path] ?? (result.path as NSString).lastPathComponent,
                originalLocation: result.path, size: result.freedBytes, timestamp: .now,
                status: result.error == nil ? .deletedPermanently : .failed, errorDescription: result.error,
                trashedPath: nil, wasPhotosAsset: false, category: "Emptied from Trash", itemCount: nil
            )
        })
    }
}
