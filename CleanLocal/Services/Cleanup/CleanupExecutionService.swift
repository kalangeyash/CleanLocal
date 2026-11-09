import Foundation
import OSLog

/// Performs the actual filesystem operation. Abstracted so tests never touch the real Trash.
protocol FileRemoving: Sendable {
    /// Moves to the Trash; returns the new location when the system reports it.
    func moveToTrash(_ url: URL) throws -> URL?
    /// Removes immediately.
    func deletePermanently(_ url: URL) throws
}

struct SystemFileRemover: FileRemoving {
    func moveToTrash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    func deletePermanently(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// The single place where cleanup candidates are removed.
///
/// For every approved candidate it re-validates with ``SafetyPolicyEngine`` (identity,
/// containment, protection, locks, running owner), then removes only the approved portion:
/// the item itself, a folder's eligible contents (never the folder), or old files (never
/// folders). Each candidate gets its own result; partial failures are reported as such.
actor CleanupExecutionService {
    private let engine: SafetyPolicyEngine
    private let remover: any FileRemoving

    init(engine: SafetyPolicyEngine, remover: any FileRemoving = SystemFileRemover()) {
        self.engine = engine
        self.remover = remover
    }

    struct Request: Sendable {
        let candidate: CleanupCandidate
        let method: CleanupMethod
    }

    func execute(
        _ requests: [Request],
        runningBundleIDs: Set<String>,
        now: Date = .now,
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async -> CleanupReport {
        var results: [CleanupItemResult] = []
        for (index, request) in requests.enumerated() {
            progress(index, requests.count)
            if Task.isCancelled {
                var result = CleanupItemResult(candidate: request.candidate, method: request.method)
                result.errors.append("Cancelled before cleaning.")
                results.append(result)
                continue
            }
            results.append(clean(request, running: runningBundleIDs, now: now))
        }
        progress(requests.count, requests.count)
        let report = CleanupReport(id: UUID(), results: results, finishedAt: .now)
        Logger.deletion.info("Cleanup: \(report.removedFiles) files, \(report.failures.count) with problems")
        return report
    }

    // MARK: - Per candidate

    private func clean(_ request: Request, running: Set<String>, now: Date) -> CleanupItemResult {
        let candidate = request.candidate
        var result = CleanupItemResult(candidate: candidate, method: request.method)

        guard let category = CleanupCatalog.category(id: candidate.categoryID) else {
            result.errors.append("Unknown cleanup category.")
            return result
        }
        guard candidate.safety != .protected else {
            result.errors.append("Protected items can’t be cleaned.")
            return result
        }
        if request.method == .deletePermanently, !category.allowsImmediateDeletion {
            result.errors.append("Immediate deletion isn’t allowed for this category.")
            return result
        }
        if category.requiresOwnerClosed, let owner = candidate.owner, running.contains(owner.bundleID) {
            result.errors.append("\(owner.name) is running. Quit it and try again.")
            return result
        }
        let allowDatabases = [.applicationCache, .browser, .developer].contains(category.group)

        switch engine.validateForRemoval(path: candidate.url.path, expectedIdentity: candidate.identity,
                                         rootPath: candidate.rootPath, allowDatabases: allowDatabases) {
        case let .failure(error):
            result.errors.append(error.localizedDescription)
            return result
        case .success:
            break
        }

        switch candidate.scope {
        case .item:
            guard let size = try? DirectorySizer.measure(candidate.url) else {
                result.errors.append(CleanLocalError.fileNotFound(path: candidate.url.path).localizedDescription)
                return result
            }
            if candidate.isDirectory, !CleanupEligibility.isChildEligible(size, now: now, activeWindow: engine.activeWindow) {
                result.errors.append("Changed in the last few minutes; skipped because it may be in use.")
                result.skippedFiles = size.fileCount
                return result
            }
            remove(candidate.url, size: size, method: request.method, into: &result)

        case .contents:
            let children = CleanupEligibility.eligibleChildren(
                of: candidate.url, excluding: CleanupEligibility.excludedChildren(for: candidate.categoryID),
                now: now, activeWindow: engine.activeWindow
            )
            // Entries left in place because they changed recently, are locked or are links.
            let excluded = CleanupEligibility.excludedChildren(for: candidate.categoryID)
            let considered = ((try? FileManager.default.contentsOfDirectory(atPath: candidate.url.path)) ?? [])
                .filter { !excluded.contains($0) && $0 != ".DS_Store" }
            result.skippedFiles = max(0, considered.count - children.count)
            for child in children {
                if Task.isCancelled { result.errors.append("Cancelled."); break }
                guard case .success = engine.validateForRemoval(path: child.url.path, expectedIdentity: nil,
                                                                rootPath: candidate.rootPath, allowDatabases: allowDatabases) else {
                    result.skippedFiles += 1
                    continue
                }
                remove(child.url, size: child.size, method: request.method, into: &result)
            }

        case let .filesOlderThan(days):
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            for file in Self.files(in: candidate.url) {
                if Task.isCancelled { result.errors.append("Cancelled."); break }
                guard let info = FileSpaceInspector.inspect(url: file), info.isRegularFile else { continue }
                guard info.modificationDate < cutoff else { continue }
                guard case .success = engine.validateForRemoval(path: file.path, expectedIdentity: info.identity,
                                                                rootPath: candidate.rootPath, allowDatabases: false) else {
                    result.skippedFiles += 1
                    continue
                }
                let size = DirectorySize(logicalSize: info.logicalSize, allocatedSize: info.allocatedSize,
                                         reclaimableSize: info.reclaimableSize, fileCount: 1, directoryCount: 0,
                                         newestModification: info.modificationDate)
                remove(file, size: size, method: request.method, into: &result)
            }
        }
        return result
    }

    private func remove(_ url: URL, size: DirectorySize, method: CleanupMethod, into result: inout CleanupItemResult) {
        do {
            switch method {
            case .moveToTrash:
                if let trashed = try remover.moveToTrash(url) { result.trashedPaths.append(trashed.path) }
            case .deletePermanently:
                try remover.deletePermanently(url)
                result.freedBytes += size.reclaimableSize
            }
            result.removedFiles += max(size.fileCount, 1)
            result.removedBytes += size.logicalSize
        } catch {
            result.skippedFiles += max(size.fileCount, 1)
            if result.errors.count < 5 {
                result.errors.append(SafeDeletionService.map(error, path: url.path).localizedDescription)
            }
        }
    }

    /// Regular files under `url`, never following symbolic links.
    private static func files(in url: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                              options: [], errorHandler: { _, _ in true }) else { return [] }
        var files: [URL] = []
        while let next = enumerator.nextObject() as? URL {
            let values = try? next.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            if values?.isRegularFile == true { files.append(next) }
        }
        return files
    }
}
