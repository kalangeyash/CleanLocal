import AppKit
import Foundation
import Observation

/// A confirm → clean → report flow for system cleanup.
struct CleanupSession: Identifiable {
    enum Phase {
        case confirming
        case cleaning(done: Int, total: Int)
        case finished(CleanupReport)
    }

    let id = UUID()
    let requests: [CleanupExecutionService.Request]
    var phase: Phase = .confirming
    /// Result of "Free space now" (permanently removing what was just moved to the Trash).
    var freeSpaceResult: FreeSpaceResult?

    var totalBytes: Int64 { requests.reduce(0) { $0 + $1.candidate.size.logicalSize } }
    var fileCount: Int { requests.reduce(0) { $0 + $1.candidate.size.fileCount } }
    var directoryCount: Int { requests.reduce(0) { $0 + $1.candidate.size.directoryCount } }
    var reviewCount: Int { requests.filter { $0.candidate.safety == .review }.count }
}

struct FreeSpaceResult: Sendable {
    let freedBytes: Int64
    let failures: [String]
    let needsTrashAccess: Bool
}

enum CleanupScanPhase: Equatable {
    case idle
    case scanning(CleanupScanProgress)
    case ready
}

/// Smart Cleanup and every category module share this store.
@MainActor
@Observable
final class CleanupStore {
    private(set) var result: CleanupScanResult?
    private(set) var phase: CleanupScanPhase = .idle
    private(set) var installedApps: [InstalledApp] = []
    var selection = Set<CleanupCandidate.ID>()
    var session: CleanupSession?
    /// Paths fully removed by a cleanup (lets the Storage Analyzer update without rescanning).
    @ObservationIgnored var onItemsRemoved: (([String]) -> Void)?

    @ObservationIgnored private let access: AccessStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let deletion: DeletionStore
    @ObservationIgnored private let trash: TrashStore
    @ObservationIgnored private let scanner: CleanupScanner
    @ObservationIgnored private let executor: CleanupExecutionService
    @ObservationIgnored private let apps: any AppCataloging
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(
        access: AccessStore, settings: SettingsStore, deletion: DeletionStore, trash: TrashStore,
        engine: SafetyPolicyEngine, remover: any FileRemoving = SystemFileRemover(),
        apps: any AppCataloging = SystemAppCatalog()
    ) {
        self.access = access
        self.settings = settings
        self.deletion = deletion
        self.trash = trash
        scanner = CleanupScanner(engine: engine)
        executor = CleanupExecutionService(engine: engine, remover: remover)
        self.apps = apps
    }

    // MARK: Derived

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    var candidates: [CleanupCandidate] { result?.candidates ?? [] }

    func candidates(in group: CleanupGroup) -> [CleanupCandidate] {
        candidates.filter { CleanupCatalog.category(id: $0.categoryID)?.group == group }
    }

    func candidates(inCategory id: String) -> [CleanupCandidate] {
        candidates.filter { $0.categoryID == id }
    }

    /// Leftovers: dedicated leftover categories plus caches/logs/state of uninstalled apps.
    var leftoverCandidates: [CleanupCandidate] {
        candidates.filter { candidate in
            CleanupCatalog.category(id: candidate.categoryID)?.group == .leftovers
                || (candidate.owner.map { !$0.isInstalled && !BundleIdentifier.isApple($0.bundleID) } ?? false)
        }
    }

    func bytes(for level: SafetyLevel, in list: [CleanupCandidate]? = nil) -> Int64 {
        (list ?? candidates).filter { $0.safety == level }.reduce(0) { $0 + $1.size.logicalSize }
    }

    var selectedCandidates: [CleanupCandidate] {
        candidates.filter { selection.contains($0.id) && $0.isSelectable }
    }

    func method(for candidate: CleanupCandidate) -> CleanupMethod {
        guard settings.deleteCachesImmediately, candidate.safety == .safe,
              CleanupCatalog.category(id: candidate.categoryID)?.allowsImmediateDeletion == true else { return .moveToTrash }
        return .deletePermanently
    }

    // MARK: Scanning

    @discardableResult
    func scan() -> Task<Void, Never>? {
        guard !isScanning, let layout = access.homeLayout else { return nil }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let thresholds = settings.cleanupThresholds
        let apps = self.apps
        let scanner = self.scanner
        phase = .scanning(CleanupScanProgress())
        let task = Task { [weak self] in
            let installed = await Task.detached { InstalledAppsScanner.scan(additionalRoots: [layout.home.appendingPathComponent("Applications")]) }.value
            let context = RuleContext(layout: layout, apps: apps, installedApps: installed, running: running, now: .now,
                                      thresholds: thresholds, ownBundleID: AppConstants.bundleIdentifier)
            do {
                let groups = Set(CleanupGroup.allCases).subtracting([.userFiles])
                let result = try await scanner.scan(groups: groups, context: context) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isScanning else { return }
                        self.phase = .scanning(progress)
                    }
                }
                guard let self else { return }
                self.installedApps = installed
                self.result = result
                // Only verified-safe items are pre-selected; review items never are.
                self.selection = Set(result.candidates.filter { $0.safety == .safe && $0.isSelectable }.map(\.id))
                self.phase = .ready
            } catch {
                self?.phase = self?.result == nil ? .idle : .ready
            }
        }
        scanTask = task
        return task
    }

    func cancelScan() {
        scanTask?.cancel()
    }

    // MARK: Cleaning

    /// Opens the preview for the given candidates (protected ones are dropped).
    func reviewCleanup(_ candidates: [CleanupCandidate]) {
        let requests = candidates.filter(\.isSelectable).map { CleanupExecutionService.Request(candidate: $0, method: method(for: $0)) }
        guard !requests.isEmpty, session == nil else { return }
        session = CleanupSession(requests: requests)
    }

    func reviewSelection(in list: [CleanupCandidate]) {
        reviewCleanup(list.filter { selection.contains($0.id) })
    }

    func confirm() async {
        guard var current = session, case .confirming = current.phase else { return }
        current.phase = .cleaning(done: 0, total: current.requests.count)
        session = current
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let report = await executor.execute(current.requests, runningBundleIDs: running) { [weak self] done, total in
            Task { @MainActor [weak self] in
                guard let self, var session = self.session, case .cleaning = session.phase else { return }
                session.phase = .cleaning(done: done, total: total)
                self.session = session
            }
        }
        apply(report)
        current.phase = .finished(report)
        session = current
    }

    /// Permanently removes what this cleanup just moved to the Trash.
    func freeSpaceNow() async {
        guard var current = session, case let .finished(report) = current.phase else { return }
        current.freeSpaceResult = await trash.deleteTrashedItems(report.trashedPaths)
        session = current
    }

    func dismissSession() {
        if case .cleaning = session?.phase { return }
        session = nil
    }

    private func apply(_ report: CleanupReport) {
        deletion.record(report.results.map { result in
            DeletionRecord(
                id: UUID(), batchID: report.id, itemID: result.candidate.id, filename: result.candidate.displayName,
                originalLocation: result.candidate.url.path, size: result.removedBytes, timestamp: report.finishedAt,
                status: result.status, errorDescription: result.errors.isEmpty ? nil : result.errors.joined(separator: " "),
                trashedPath: result.trashedPaths.count == 1 ? result.trashedPaths.first : nil, wasPhotosAsset: false,
                category: CleanupCatalog.category(id: result.candidate.categoryID)?.title, itemCount: result.removedFiles
            )
        })
        guard var updated = result else {
            onItemsRemoved?(report.results.filter { $0.candidate.scope == .item && $0.removedFiles > 0 && $0.errors.isEmpty }.map(\.candidate.id))
            return
        }
        let finished = Dictionary(uniqueKeysWithValues: report.results.map { ($0.candidate.id, $0) })
        updated.candidates = updated.candidates.compactMap { candidate in
            guard let outcome = finished[candidate.id], outcome.removedFiles > 0 else { return candidate }
            if outcome.skippedFiles == 0 && outcome.errors.isEmpty { return nil }
            var remaining = candidate
            remaining.size.logicalSize = max(0, candidate.size.logicalSize - outcome.removedBytes)
            remaining.size.fileCount = max(0, candidate.size.fileCount - outcome.removedFiles)
            return remaining
        }
        result = updated
        selection.subtract(report.results.filter { $0.removedFiles > 0 }.map(\.candidate.id))
        onItemsRemoved?(report.results.filter { $0.candidate.scope == .item && $0.removedFiles > 0 && $0.errors.isEmpty }.map(\.candidate.id))
    }

    func reset() {
        result = nil
        selection = []
        phase = .idle
    }
}
