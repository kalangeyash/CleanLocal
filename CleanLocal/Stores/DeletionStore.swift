import Foundation
import Observation

/// Which window a deletion flow belongs to, so its sheet appears in the right place.
enum DeletionContext: Hashable {
    case main
    case preview(MediaItem.ID)
}

/// A pending or completed user-initiated deletion.
struct DeletionSession: Identifiable {
    enum Phase {
        case confirming
        case deleting
        case finished(DeletionReport)
    }

    let id = UUID()
    let items: [MediaItem]
    let context: DeletionContext
    /// Duplicate groups in which every copy is selected (warned about explicitly).
    let fullySelectedGroupCount: Int
    var phase: Phase = .confirming

    var totalBytes: Int64 { items.reduce(0) { $0 + $1.size } }
    var photosItemCount: Int { items.filter(\.isPhotosAsset).count }
    var fileItemCount: Int { items.count - photosItemCount }
}

/// Owns the confirm → delete → report flow and the deletion history.
@MainActor
@Observable
final class DeletionStore {
    private(set) var history: [DeletionRecord] = []
    var session: DeletionSession?

    @ObservationIgnored private let service: SafeDeletionService
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let analysis: AnalysisStore
    @ObservationIgnored private let persistence: PersistenceController

    init(service: SafeDeletionService, library: LibraryStore, analysis: AnalysisStore, persistence: PersistenceController) {
        self.service = service
        self.library = library
        self.analysis = analysis
        self.persistence = persistence
    }

    func bootstrap() async {
        history = await persistence.deletionHistory.load()
    }

    // MARK: Flow

    /// Opens the confirmation sheet. Nothing is removed until `confirm()` is called.
    func requestDeletion(of items: [MediaItem], context: DeletionContext = .main) {
        guard !items.isEmpty, session == nil else { return }
        let ids = Set(items.map(\.id))
        let fullySelected = DuplicateSelectionPolicy.groupsFullySelected(by: ids, in: analysis.duplicateGroups).count
        session = DeletionSession(items: items, context: context, fullySelectedGroupCount: fullySelected)
    }

    func confirm() async {
        guard var current = session, case .confirming = current.phase else { return }
        current.phase = .deleting
        session = current

        let report = await service.remove(current.items, authorizedRoots: library.authorizedRoots())
        let removed = report.succeededItemIDs
        library.removeItems(withIDs: removed)
        analysis.itemsWereRemoved(removed)

        history.insert(contentsOf: report.records, at: 0)
        persistHistory()

        current.phase = .finished(report)
        session = current
    }

    func dismiss() {
        if case .deleting = session?.phase { return }
        session = nil
    }

    // MARK: History

    /// Bytes successfully moved to the Trash or Recently Deleted (never failures).
    var totalReclaimedBytes: Int64 {
        history.filter { $0.status.succeeded }.reduce(0) { $0 + $1.size }
    }

    /// Adds records produced by other cleanup flows (system cleanup, Trash emptying).
    func record(_ records: [DeletionRecord]) {
        guard !records.isEmpty else { return }
        history.insert(contentsOf: records, at: 0)
        persistHistory()
    }

    /// Paths CleanLocal moved to the Trash in the current session's report.
    var lastTrashedPaths: [String] {
        guard case let .finished(report)? = session?.phase else { return [] }
        return report.records.compactMap(\.trashedPath)
    }

    func clearHistory() {
        history = []
        Task { try? await persistence.deletionHistory.reset() }
    }

    private func persistHistory() {
        let snapshot = Array(history.prefix(5_000))
        Task { try? await persistence.deletionHistory.save(snapshot) }
    }
}
