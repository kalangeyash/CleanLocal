import Foundation

extension Collection where Element: Sendable {
    /// Maps elements concurrently with at most `maxConcurrency` child tasks in flight,
    /// preserving input order. Cancelling the parent task cancels outstanding work.
    func concurrentMap<T: Sendable>(
        maxConcurrency: Int,
        _ transform: @escaping @Sendable (Element) async throws -> T
    ) async throws -> [T] {
        let limit = Swift.max(1, maxConcurrency)
        let elements = Array(self)
        guard !elements.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (Int, T).self) { group in
            var results = [T?](repeating: nil, count: elements.count)
            var nextIndex = 0

            func addNext() {
                let index = nextIndex
                let element = elements[index]
                group.addTask { (index, try await transform(element)) }
                nextIndex += 1
            }

            while nextIndex < Swift.min(limit, elements.count) { addNext() }

            while let (index, value) = try await group.next() {
                results[index] = value
                try Task.checkCancellation()
                if nextIndex < elements.count { addNext() }
            }
            return results.compactMap { $0 }
        }
    }
}

/// A counting semaphore for async code. Used to cap expensive work such as
/// thumbnail generation regardless of how many views ask at once.
actor AsyncSemaphore {
    private var permits: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(permits: Int) {
        self.permits = permits
    }

    func acquire() async {
        if permits > 0 {
            permits -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            permits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `operation` while holding a permit.
    func withPermit<T: Sendable>(_ operation: @Sendable () async throws -> T) async rethrows -> T {
        await acquire()
        defer { release() }
        return try await operation()
    }
}

/// Limits how often a progress callback fires so the UI is not flooded.
struct ProgressThrottle: Sendable {
    private let interval: Duration
    private var last: ContinuousClock.Instant?

    init(interval: Duration = .milliseconds(80)) {
        self.interval = interval
    }

    mutating func shouldFire(force: Bool = false) -> Bool {
        let now = ContinuousClock.now
        if force || last == nil || now - (last ?? now) >= interval {
            last = now
            return true
        }
        return false
    }
}
