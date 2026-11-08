import Foundation

/// Finds visually similar photos using perceptual hashes.
///
/// Similar photos are **never** treated as duplicates: groups are presented for manual
/// review only, and nothing in them is selected automatically.
struct SimilarityDetectionService: Sendable {
    var maxConcurrency = AppConstants.Scanning.metadataConcurrency
    var photosHasher: (any PhotosContentHashing)?

    /// Computes perceptual hashes for images that don't have cached ones.
    func computeHashes(
        for items: [MediaItem],
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [MediaItem.ID: PerceptualHasher.Hashes] {
        let pending = items.filter { $0.kind == .image && ($0.perceptualHash == nil || $0.differenceHash == nil) }
        guard !pending.isEmpty else { return [:] }

        let total = Double(pending.count)
        let counter = ProgressCounter()
        let photosHasher = self.photosHasher
        let results = try await pending.concurrentMap(maxConcurrency: maxConcurrency) { item -> (MediaItem.ID, PerceptualHasher.Hashes?) in
            try Task.checkCancellation()
            defer { progress(Double(counter.increment()) / total) }
            if item.isPhotosAsset {
                guard let identifier = item.photosLocalIdentifier else { return (item.id, nil) }
                return (item.id, await photosHasher?.perceptualHashes(forLocalIdentifier: identifier))
            }
            guard let url = item.url else { return (item.id, nil) }
            return (item.id, autoreleasepool { PerceptualHasher.hashes(forImageAt: url) })
        }
        return Dictionary(results.compactMap { id, hashes in hashes.map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// Clusters images whose hashes are within `maxDistance` bits of each other.
    ///
    /// Two images are linked when both their pHash and dHash agree and their aspect ratios
    /// are compatible. Near-uniform images (blank frames, solid colors) are excluded because
    /// their hashes carry too little information to compare reliably.
    static func groupSimilar(_ items: [MediaItem], maxDistance: Int) throws -> [DuplicateGroup] {
        let candidates = items.filter { item in
            guard item.kind == .image, item.perceptualHash != nil, let difference = item.differenceHash else { return false }
            return difference.nonzeroBitCount > 2 && difference.nonzeroBitCount < 62
        }
        guard candidates.count > 1 else { return [] }

        let secondaryLimit = maxDistance + 6
        var parent = Array(candidates.indices)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var node = index
            while parent[node] != root { (node, parent[node]) = (parent[node], root) }
            return root
        }

        var distanceSums: [Int: (total: Int, pairs: Int)] = [:]
        var links: [(Int, Int, Int)] = []
        let hashes = candidates.map { ($0.perceptualHash ?? 0, $0.differenceHash ?? 0, aspectRatio(of: $0)) }

        for i in 0..<hashes.count {
            if i % 256 == 0, Task.isCancelled { throw CancellationError() }
            let (pHashA, dHashA, ratioA) = hashes[i]
            for j in (i + 1)..<hashes.count {
                let (pHashB, dHashB, ratioB) = hashes[j]
                let distance = PerceptualHasher.distance(pHashA, pHashB)
                guard distance <= maxDistance,
                      PerceptualHasher.distance(dHashA, dHashB) <= secondaryLimit,
                      aspectRatiosCompatible(ratioA, ratioB) else { continue }
                links.append((i, j, distance))
                let rootA = find(i), rootB = find(j)
                if rootA != rootB { parent[rootB] = rootA }
            }
        }

        for (i, _, distance) in links {
            let root = find(i)
            distanceSums[root, default: (0, 0)].total += distance
            distanceSums[root, default: (0, 0)].pairs += 1
        }

        var clusters: [Int: [MediaItem]] = [:]
        for index in candidates.indices {
            clusters[find(index), default: []].append(candidates[index])
        }

        return clusters.compactMap { root, members -> DuplicateGroup? in
            guard members.count > 1 else { return nil }
            // Byte-identical sets are already reported as exact duplicates.
            let hashes = Set(members.compactMap(\.contentHash))
            if hashes.count == 1, members.allSatisfy({ $0.contentHash != nil }) { return nil }

            let stats = distanceSums[root] ?? (0, 1)
            let averageDistance = Double(stats.total) / Double(max(stats.pairs, 1))
            let keeper = DuplicateSelectionPolicy.suggestedKeeper(forSimilar: members)
            let ordered = members.sorted { lhs, rhs in
                if lhs.id == keeper { return true }
                if rhs.id == keeper { return false }
                return lhs.effectiveDate < rhs.effectiveDate
            }
            return DuplicateGroup(
                id: "similar-" + ordered.map(\.id).sorted().joined(separator: "|"),
                kind: .similar,
                items: ordered,
                suggestedKeeperID: keeper,
                similarity: 1 - averageDistance / 64
            )
        }
        .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    private static func aspectRatio(of item: MediaItem) -> Double? {
        guard let width = item.pixelWidth, let height = item.pixelHeight, width > 0, height > 0 else { return nil }
        return Double(width) / Double(height)
    }

    private static func aspectRatiosCompatible(_ lhs: Double?, _ rhs: Double?) -> Bool {
        guard let lhs, let rhs else { return true }
        return abs(lhs - rhs) / max(lhs, rhs) < 0.12
    }
}
