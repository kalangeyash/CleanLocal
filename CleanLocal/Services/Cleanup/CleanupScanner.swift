import Foundation
import OSLog

/// Sizing and eligibility rules shared by the scanner and the executor, so what the user
/// approves is exactly what gets removed.
enum CleanupEligibility {
    /// Temporary sub-folders reported by their own category, not double-counted as caches.
    static let temporaryFolderNames: Set<String> = ["tmp", "Temp", "temp", "TemporaryItems"]

    static func excludedChildren(for categoryID: String) -> Set<String> {
        categoryID == "app-caches" ? temporaryFolderNames : []
    }

    /// A child of a `.contents` candidate is eligible only if nothing inside it changed
    /// within the active window.
    static func isChildEligible(_ size: DirectorySize, now: Date, activeWindow: TimeInterval) -> Bool {
        guard let newest = size.newestModification else { return true }
        return now.timeIntervalSince(newest) >= activeWindow
    }

    static func eligibleChildren(
        of url: URL, excluding: Set<String>, now: Date, activeWindow: TimeInterval
    ) -> [(url: URL, size: DirectorySize)] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else { return [] }
        return names.compactMap { name in
            guard !excluding.contains(name), name != ".DS_Store" else { return nil }
            let child = url.appendingPathComponent(name)
            guard let info = FileSpaceInspector.inspect(url: child), !info.isSymbolicLink, !info.isImmutable,
                  let size = try? DirectorySizer.measure(child),
                  isChildEligible(size, now: now, activeWindow: activeWindow) else { return nil }
            return (child, size)
        }
    }

    /// Size of exactly what `scope` would remove.
    static func measure(_ url: URL, scope: CleanupScope, categoryID: String, now: Date, activeWindow: TimeInterval) throws -> DirectorySize {
        switch scope {
        case .item:
            return try DirectorySizer.measure(url)
        case .contents:
            return eligibleChildren(of: url, excluding: excludedChildren(for: categoryID), now: now, activeWindow: activeWindow)
                .reduce(DirectorySize()) { $0 + $1.size }
        case let .filesOlderThan(days):
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            var size = try DirectorySizer.measure(url) { _, info in info.isDirectory || info.modificationDate < cutoff }
            size.directoryCount = 0 // folders are kept
            return size
        }
    }
}

/// Runs the cleanup rules and turns their findings into classified, sized candidates.
actor CleanupScanner {
    private let engine: SafetyPolicyEngine
    private let rules: [CleanupRule]

    init(engine: SafetyPolicyEngine, rules: [CleanupRule] = CleanupRules.all()) {
        self.engine = engine
        self.rules = rules
    }

    func scan(
        groups: Set<CleanupGroup>,
        context: RuleContext,
        progress: @escaping @Sendable (CleanupScanProgress) -> Void = { _ in }
    ) async throws -> CleanupScanResult {
        let started = Date.now
        let selectedRules = rules.filter { rule in
            CleanupCatalog.category(id: rule.categoryID).map { groups.contains($0.group) } ?? false
        }
        var state = CleanupScanProgress(totalCategories: selectedRules.count)
        var candidates: [CleanupCandidate] = []
        var issues: [AccessIssue] = []
        var seenPaths = Set<String>()
        let engine = self.engine
        let roots = [context.layout.home] + context.layout.projectRoots

        for rule in selectedRules {
            try Task.checkCancellation()
            guard let category = CleanupCatalog.category(id: rule.categoryID) else { continue }
            state.categoryTitle = category.title
            progress(state)

            let drafts: [CandidateDraft]
            do {
                drafts = try rule.discover(context)
            } catch let error as RuleAccessError {
                issues.append(AccessIssue(path: error.path, reason: error.reason))
                drafts = []
            }

            let unique = drafts.filter { seenPaths.insert($0.url.path).inserted }
            let built = try await unique.concurrentMap(maxConcurrency: 4) { draft -> CleanupCandidate? in
                try Task.checkCancellation()
                let categoryID = draft.categoryID ?? rule.categoryID
                guard let draftCategory = CleanupCatalog.category(id: categoryID),
                      let info = FileSpaceInspector.inspect(url: draft.url) else { return nil }
                let size = (try? CleanupEligibility.measure(draft.url, scope: draft.scope, categoryID: categoryID,
                                                            now: context.now, activeWindow: engine.activeWindow)) ?? DirectorySize()
                let root = roots.filter { draft.url.path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }
                var candidate = CleanupCandidate(
                    id: draft.url.path, url: draft.url, categoryID: categoryID, displayName: draft.name, detail: draft.detail,
                    scope: draft.scope, safety: draft.safety, reasons: draft.reasons, owner: draft.owner,
                    isDirectory: info.isDirectory, size: size, identity: info.identity,
                    rootPath: root?.path ?? context.layout.home.path
                )
                let (level, reasons) = engine.classify(candidate, category: draftCategory, info: info,
                                                       context: .init(runningBundleIDs: context.running, now: context.now))
                candidate.safety = level
                candidate.reasons = reasons
                return candidate
            }
            let meaningful = built.compactMap { $0 }.filter { $0.size.logicalSize > 0 || $0.size.fileCount > 0 }
            candidates += meaningful
            state.completedCategories += 1
            state.itemsFound += meaningful.count
            state.bytesFound += meaningful.filter { $0.safety != .protected }.reduce(0) { $0 + $1.size.logicalSize }
            progress(state)
        }

        Logger.scanning.info("Cleanup scan: \(candidates.count) candidates, \(issues.count) inaccessible locations")
        return CleanupScanResult(
            candidates: candidates.sorted { $0.size.logicalSize > $1.size.logicalSize },
            issues: issues,
            scannedAt: .now,
            duration: Date.now.timeIntervalSince(started)
        )
    }
}
