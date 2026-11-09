import Foundation

/// Hashing for Photos library assets, implemented with PhotoKit.
protocol PhotosContentHashing: Sendable {
    /// SHA-256 of the asset's original resource, streamed (never fully in memory).
    /// `allowNetwork` lets Photos fetch an iCloud-only original (user opt-in).
    func contentHash(forLocalIdentifier identifier: String, allowNetwork: Bool) async throws -> String
    func perceptualHashes(forLocalIdentifier identifier: String) async -> PerceptualHasher.Hashes?
}

struct DuplicateDetectionResult: Sendable {
    var groups: [DuplicateGroup]
    /// Newly computed content hashes, to be cached in the index.
    var computedHashes: [MediaItem.ID: String]
    /// Items that could not be read (e.g. iCloud-only originals, permission changes).
    var unreadableCount: Int
    /// iCloud-only Photos assets matched by metadata and appearance (bytes not compared).
    var probableGroups: [DuplicateGroup] = []
}

/// Finds byte-identical media in three stages:
///
/// 1. **Metadata** – group by kind and exact byte size (and dimensions when every member's
///    dimensions come from the same reader). Unique sizes can't have duplicates.
/// 2. **Edge fingerprint** – hash the first/last 64 KB of each remaining file to cheaply split
///    groups that merely share a size.
/// 3. **SHA-256** – full streaming content hash. Only identical hashes form a group.
///
/// Cached hashes from earlier runs are reused, so re-analysis only reads new or changed files.
struct DuplicateDetectionService: Sendable {
    var maxConcurrency = AppConstants.Scanning.hashingConcurrency
    var photosHasher: (any PhotosContentHashing)?
    /// Let Photos download iCloud-only originals to verify them (off unless the user opts in).
    var allowPhotosNetwork = false

    func findExactDuplicates(
        in items: [MediaItem],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> DuplicateDetectionResult {
        // Stage 1: metadata grouping.
        let sizeGroups = Dictionary(grouping: items.filter { $0.size > 0 }) { "\($0.kind.rawValue)|\($0.size)" }
            .values
            .filter { $0.count > 1 }
            .flatMap(Self.splitByDimensions)
            .filter { $0.count > 1 }

        // Stage 2: edge fingerprints for regular files without a cached full hash.
        let needingEdge = sizeGroups.joined().filter { $0.contentHash == nil && !$0.isPhotosAsset }
        let edgePairs = try await needingEdge.concurrentMap(maxConcurrency: maxConcurrency) { item -> (MediaItem.ID, String?) in
            guard let url = item.url else { return (item.id, nil) }
            return (item.id, try? FileHasher.edgeFingerprint(of: url))
        }
        let edges = Dictionary(edgePairs.compactMap { pair in pair.1.map { (pair.0, $0) } }, uniquingKeysWith: { first, _ in first })

        var fullHashCandidates: [MediaItem] = []
        for group in sizeGroups {
            // Items with a cached full hash or Photos assets skip the edge stage.
            let bucketed = Dictionary(grouping: group) { item -> String in
                if item.contentHash != nil || item.isPhotosAsset { return "*" }
                return edges[item.id] ?? "unreadable-\(item.id)"
            }
            let wildcard = bucketed["*"] ?? []
            for (key, bucket) in bucketed where key != "*" && !key.hasPrefix("unreadable-") {
                if bucket.count + wildcard.count > 1 { fullHashCandidates += bucket }
            }
            if wildcard.count > 1 || (wildcard.count == 1 && bucketed.count > 1) {
                fullHashCandidates += wildcard
            }
        }

        // Stage 3: full SHA-256 (reusing cached values).
        let total = max(1, fullHashCandidates.count)
        let counter = ProgressCounter()
        let photosHasher = self.photosHasher
        let allowNetwork = allowPhotosNetwork
        let hashed = try await fullHashCandidates.concurrentMap(maxConcurrency: maxConcurrency) { item -> (MediaItem, String?, Bool) in
            defer { progress(Double(counter.increment()) / Double(total)) }
            if let cached = item.contentHash { return (item, cached, false) }
            do {
                if item.isPhotosAsset {
                    guard let identifier = item.photosLocalIdentifier, let photosHasher else { return (item, nil, false) }
                    return (item, try await photosHasher.contentHash(forLocalIdentifier: identifier, allowNetwork: allowNetwork), true)
                }
                guard let url = item.url else { return (item, nil, false) }
                return (item, try FileHasher.sha256(of: url), true)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                return (item, nil, false)
            }
        }

        var computed: [MediaItem.ID: String] = [:]
        var byHash: [String: [MediaItem]] = [:]
        var unreadable = 0
        var unreadablePhotos: [MediaItem] = []
        for (item, hash, isNew) in hashed {
            guard let hash else {
                unreadable += 1
                if item.isPhotosAsset { unreadablePhotos.append(item) }
                continue
            }
            if isNew { computed[item.id] = hash }
            var updated = item
            updated.contentHash = hash
            byHash[hash, default: []].append(updated)
        }

        let groups = byHash
            .filter { $0.value.count > 1 }
            .map { hash, members in
                let keeper = DuplicateSelectionPolicy.suggestedKeeper(forExactDuplicates: members)
                return DuplicateGroup(
                    id: "exact-" + hash,
                    kind: .exact,
                    items: DuplicateSelectionPolicy.orderedForDisplay(members, keeperID: keeper),
                    suggestedKeeperID: keeper,
                    similarity: 1
                )
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }

        // Photos assets we couldn't read (iCloud-only) or size (unknown) get a metadata match.
        let probableInput = unreadablePhotos + items.filter { $0.isPhotosAsset && $0.size == 0 }
        let probable = try await probableDuplicates(among: probableInput)

        progress(1)
        return DuplicateDetectionResult(groups: groups, computedHashes: computed, unreadableCount: unreadable, probableGroups: probable)
    }

    /// Groups Photos assets with identical dimensions, capture time and duration whose
    /// local thumbnails are visually indistinguishable. Used only when bytes can't be read.
    func probableDuplicates(among items: [MediaItem]) async throws -> [DuplicateGroup] {
        let keyed = Dictionary(grouping: items.filter { $0.creationDate != nil }) { item -> String in
            let created = Int(item.creationDate?.timeIntervalSince1970 ?? 0)
            let duration = item.duration.map { Int(($0 * 2).rounded()) } ?? -1
            return "\(item.kind.rawValue)|\(item.pixelWidth ?? 0)x\(item.pixelHeight ?? 0)|\(created)|\(duration)"
        }
        var groups: [DuplicateGroup] = []
        for members in keyed.values where members.count > 1 {
            try Task.checkCancellation()
            var hashes: [MediaItem.ID: UInt64] = [:]
            if let photosHasher {
                for member in members {
                    if let identifier = member.photosLocalIdentifier,
                       let value = await photosHasher.perceptualHashes(forLocalIdentifier: identifier) {
                        hashes[member.id] = value.perceptual
                    }
                }
            }
            // Require matching appearance when fingerprints are available.
            var clusters: [[MediaItem]] = []
            for member in members {
                if let index = clusters.firstIndex(where: { cluster in
                    guard let a = hashes[cluster[0].id], let b = hashes[member.id] else { return hashes.isEmpty }
                    return PerceptualHasher.distance(a, b) <= 3
                }) {
                    clusters[index].append(member)
                } else {
                    clusters.append([member])
                }
            }
            for cluster in clusters where cluster.count > 1 {
                let keeper = DuplicateSelectionPolicy.suggestedKeeper(forExactDuplicates: cluster)
                groups.append(DuplicateGroup(
                    id: "probable-" + cluster.map(\.id).sorted().joined(separator: "|"),
                    kind: .probable,
                    items: DuplicateSelectionPolicy.orderedForDisplay(cluster, keeperID: keeper),
                    suggestedKeeperID: keeper,
                    similarity: 0.99
                ))
            }
        }
        return groups
    }

    /// Splits a same-size group by pixel dimensions, but only when every member is a regular
    /// file with known dimensions (Photos and file readers may disagree on orientation).
    private static func splitByDimensions(_ group: [MediaItem]) -> [[MediaItem]] {
        let allComparable = group.allSatisfy { !$0.isPhotosAsset && $0.pixelWidth != nil && $0.pixelHeight != nil }
        guard allComparable else { return [group] }
        return Array(Dictionary(grouping: group) { "\($0.pixelWidth ?? 0)x\($0.pixelHeight ?? 0)" }.values)
    }
}

/// Rules for recommending which copy to keep and what may be auto-selected.
///
/// Safety invariants (covered by tests):
/// * Auto-selection never includes a group's suggested keeper.
/// * Auto-selection never selects anything in a group with fewer than two items.
enum DuplicateSelectionPolicy {
    private static let transientFolders = ["/Downloads/", "/Desktop/", "/tmp/", "/Temp/"]

    /// Prefers the copy that looks like the "original": organized location, Photos library,
    /// no "copy" marker in the name, oldest date, shortest path.
    static func suggestedKeeper(forExactDuplicates items: [MediaItem]) -> MediaItem.ID {
        func score(_ item: MediaItem) -> (Int, Int, Int, Date, Int, String) {
            let path = item.path ?? ""
            let isTransient = transientFolders.contains { path.contains($0) } ? 1 : 0
            let notPhotos = item.isPhotosAsset ? 0 : 1
            let looksCopied = looksLikeCopy(item.filename) ? 1 : 0
            return (isTransient, notPhotos, looksCopied, item.effectiveDate, path.count, item.id)
        }
        return items.min { score($0) < score($1) }?.id ?? items.first?.id ?? ""
    }

    /// For visually similar photos, suggests the best-quality version: most pixels, then
    /// largest file, then the oldest.
    static func suggestedKeeper(forSimilar items: [MediaItem]) -> MediaItem.ID {
        items.max { lhs, rhs in
            if lhs.pixelCount != rhs.pixelCount { return lhs.pixelCount < rhs.pixelCount }
            if lhs.size != rhs.size { return lhs.size < rhs.size }
            return lhs.effectiveDate > rhs.effectiveDate
        }?.id ?? items.first?.id ?? ""
    }

    /// Everything except each group's keeper. Never selects the only copy of anything.
    static func autoSelection(for groups: [DuplicateGroup]) -> Set<MediaItem.ID> {
        var selection = Set<MediaItem.ID>()
        for group in groups where group.items.count > 1 {
            for item in group.items where item.id != group.suggestedKeeperID {
                selection.insert(item.id)
            }
        }
        return selection
    }

    /// Groups in which `selection` would remove every copy. Used to warn before deletion.
    static func groupsFullySelected(by selection: Set<MediaItem.ID>, in groups: [DuplicateGroup]) -> [DuplicateGroup] {
        groups.filter { group in !group.items.isEmpty && group.items.allSatisfy { selection.contains($0.id) } }
    }

    static func orderedForDisplay(_ items: [MediaItem], keeperID: MediaItem.ID) -> [MediaItem] {
        items.sorted { lhs, rhs in
            if lhs.id == keeperID { return true }
            if rhs.id == keeperID { return false }
            return lhs.effectiveDate < rhs.effectiveDate
        }
    }

    static func looksLikeCopy(_ filename: String) -> Bool {
        let stem = (filename as NSString).deletingPathExtension.lowercased()
        if stem.hasSuffix(" copy") || stem.contains(" copy ") { return true }
        // "IMG_0001 (1)", "photo(2)"
        if let open = stem.lastIndex(of: "("), stem.hasSuffix(")") {
            let inner = stem[stem.index(after: open)..<stem.index(before: stem.endIndex)]
            return !inner.isEmpty && inner.allSatisfy(\.isNumber)
        }
        return false
    }
}

/// Thread-safe counter for progress reporting from concurrent tasks.
final class ProgressCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func increment() -> Int {
        lock.withLock {
            value += 1
            return value
        }
    }
}
