import Foundation
import Observation

enum AnalysisPhase: Equatable {
    case notStarted
    case running(progress: Double, message: String)
    case completed(Date)
    case failed(String)

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
}

/// Exact-duplicate and similar-photo analysis over the current index.
@MainActor
@Observable
final class AnalysisStore {
    private(set) var duplicateGroups: [DuplicateGroup] = []
    private(set) var similarGroups: [DuplicateGroup] = []
    private(set) var duplicatePhase: AnalysisPhase = .notStarted
    private(set) var similarPhase: AnalysisPhase = .notStarted
    private(set) var unreadableDuplicateCandidates = 0
    /// Bytes freed by removing every non-keeper copy in exact duplicate groups.
    private(set) var reclaimableDuplicateBytes: Int64 = 0
    /// Number of redundant copies (all members minus one keeper per group).
    private(set) var redundantCopyCount = 0

    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let duplicateService: DuplicateDetectionService
    @ObservationIgnored private let similarityService: SimilarityDetectionService
    @ObservationIgnored private var duplicateTask: Task<Void, Never>?
    @ObservationIgnored private var similarTask: Task<Void, Never>?

    init(library: LibraryStore, settings: SettingsStore, duplicateService: DuplicateDetectionService, similarityService: SimilarityDetectionService) {
        self.library = library
        self.settings = settings
        self.duplicateService = duplicateService
        self.similarityService = similarityService
    }

    // MARK: Exact duplicates

    @discardableResult
    func analyzeDuplicates() -> Task<Void, Never>? {
        duplicateTask?.cancel()
        let items = library.items
        let service = duplicateService
        duplicatePhase = .running(progress: 0, message: "Comparing \(items.count.formatted()) files…")
        duplicateTask = Task { [weak self] in
            do {
                let result = try await service.findExactDuplicates(in: items) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.duplicatePhase.isRunning else { return }
                        self.duplicatePhase = .running(progress: fraction, message: "Verifying candidates with SHA-256…")
                    }
                }
                guard let self, !Task.isCancelled else { return }
                library.applyContentHashes(result.computedHashes)
                setDuplicateGroups(result.groups)
                unreadableDuplicateCandidates = result.unreadableCount
                duplicatePhase = .completed(.now)
            } catch is CancellationError {
                // Superseded or stopped: whoever cancelled owns the phase now.
            } catch {
                guard !Task.isCancelled else { return }
                self?.duplicatePhase = .failed(error.localizedDescription)
            }
        }
        return duplicateTask
    }

    func cancelDuplicateAnalysis() {
        duplicateTask?.cancel()
        duplicatePhase = .notStarted
    }

    private func setDuplicateGroups(_ groups: [DuplicateGroup]) {
        duplicateGroups = groups
        reclaimableDuplicateBytes = StorageAnalyticsService.reclaimableBytes(in: groups)
        redundantCopyCount = groups.reduce(0) { $0 + max(0, $1.items.count - 1) }
    }

    // MARK: Similar photos

    @discardableResult
    func analyzeSimilar() -> Task<Void, Never>? {
        similarTask?.cancel()
        let images = library.items.filter { $0.kind == .image }
        let service = similarityService
        let maxDistance = PerceptualHasher.maximumDistance(forSimilarity: settings.similarityThreshold)
        similarPhase = .running(progress: 0, message: "Fingerprinting \(images.count.formatted()) photos…")
        similarTask = Task { [weak self] in
            do {
                let hashes = try await service.computeHashes(for: images) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.similarPhase.isRunning else { return }
                        self.similarPhase = .running(progress: fraction * 0.9, message: "Fingerprinting photos…")
                    }
                }
                guard let self, !Task.isCancelled else { return }
                library.applyPerceptualHashes(hashes)
                similarPhase = .running(progress: 0.95, message: "Grouping similar photos…")
                let hashed = library.items.filter { $0.kind == .image }
                let groups = try await Task.detached(priority: .userInitiated) {
                    try SimilarityDetectionService.groupSimilar(hashed, maxDistance: maxDistance)
                }.value
                guard !Task.isCancelled else { return }
                similarGroups = groups
                similarPhase = .completed(.now)
            } catch is CancellationError {
                // Superseded or stopped: whoever cancelled owns the phase now.
            } catch {
                guard !Task.isCancelled else { return }
                self?.similarPhase = .failed(error.localizedDescription)
            }
        }
        return similarTask
    }

    func cancelSimilarAnalysis() {
        similarTask?.cancel()
        similarPhase = .notStarted
    }

    // MARK: Library events

    /// Called after a scan completes.
    func libraryDidRescan() {
        if settings.analyzeDuplicatesAfterScan || duplicatePhase != .notStarted {
            analyzeDuplicates()
        }
        if case .completed = similarPhase { analyzeSimilar() }
    }

    /// Prunes deleted items from existing groups without re-running analysis.
    func itemsWereRemoved(_ ids: Set<MediaItem.ID>) {
        setDuplicateGroups(Self.prune(duplicateGroups, removing: ids, keeperRule: DuplicateSelectionPolicy.suggestedKeeper(forExactDuplicates:)))
        similarGroups = Self.prune(similarGroups, removing: ids, keeperRule: DuplicateSelectionPolicy.suggestedKeeper(forSimilar:))
    }

    func reset() {
        duplicateTask?.cancel()
        similarTask?.cancel()
        setDuplicateGroups([])
        similarGroups = []
        duplicatePhase = .notStarted
        similarPhase = .notStarted
    }

    nonisolated static func prune(
        _ groups: [DuplicateGroup],
        removing ids: Set<MediaItem.ID>,
        keeperRule: ([MediaItem]) -> MediaItem.ID
    ) -> [DuplicateGroup] {
        groups.compactMap { group in
            var group = group
            group.items.removeAll { ids.contains($0.id) }
            guard group.items.count > 1 else { return nil }
            if !group.items.contains(where: { $0.id == group.suggestedKeeperID }) {
                group.suggestedKeeperID = keeperRule(group.items)
            }
            return group
        }
    }
}
