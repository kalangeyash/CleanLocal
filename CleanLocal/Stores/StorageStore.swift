import Foundation
import Observation

/// One slice of "what's using my disk".
struct StorageArea: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let symbolName: String
    let bytes: Int64
    let detail: String
    /// Where to go to act on it.
    let destination: SidebarDestination?
    /// Measured by CleanLocal (vs. inferred from the volume total).
    let isMeasured: Bool
}

/// Partitions used disk space into areas without double counting.
enum StorageBreakdownService {
    static let developerCachePaths = [
        ".npm", ".gradle", ".android", ".cargo", ".rustup", ".m2", ".cache", ".local", ".vscode", ".nuget", ".pub-cache",
        "Library/pnpm", "Library/Caches/ms-playwright", "Library/Caches/pnpm", "Library/Caches/node-gyp", "Library/Caches/Homebrew",
        "Library/Caches/CocoaPods", "Library/Caches/org.swift.swiftpm", "Library/Caches/pip", "Library/Caches/Yarn", "Library/Caches/go-build",
    ]

    static func areas(
        tree: DiskTree?,
        pathIndex: [String: Int],
        homePath: String,
        applicationsBytes: Int64?,
        systemVolumeUsed: Int64?,
        dataVolume: VolumeCapacity?,
        purgeable: Int64?
    ) -> [StorageArea] {
        var areas: [StorageArea] = []
        func size(_ relative: String) -> Int64 {
            pathIndex[homePath + "/" + relative].map { tree?.nodes[$0].allocatedSize ?? 0 } ?? 0
        }
        func add(_ id: String, _ title: String, _ symbol: String, _ bytes: Int64, _ detail: String, _ destination: SidebarDestination?) {
            guard bytes > 0 else { return }
            areas.append(StorageArea(id: id, title: title, symbolName: symbol, bytes: bytes, detail: detail,
                                     destination: destination, isMeasured: true))
        }

        if let tree {
            let photos = tree.nodes.filter { $0.kind == .package && $0.path.hasSuffix(".photoslibrary") }.reduce(Int64(0)) { $0 + $1.allocatedSize }
            let developerCaches = developerCachePaths.reduce(Int64(0)) { $0 + size($1) }
            let libraryCachesDeveloper = developerCachePaths.filter { $0.hasPrefix("Library/Caches/") }.reduce(Int64(0)) { $0 + size($1) }
            let appCaches = max(0, size("Library/Caches") - libraryCachesDeveloper)
            let appData = size("Library/Application Support") + size("Library/Containers") + size("Library/Group Containers")
            let xcode = size("Library/Developer")
            let iCloud = size("Library/Mobile Documents")
            let libraryAccounted = size("Library/Caches") + size("Library/pnpm") + appData + xcode + iCloud
            let libraryOther = max(0, size("Library") - libraryAccounted)
            let downloads = size("Downloads")
            let documents = size("Documents") + size("Desktop")
            let trash = size(".Trash")
            let homeAccounted = size("Library") + downloads + documents + trash + photos
                + developerCachePaths.filter { !$0.hasPrefix("Library/") }.reduce(Int64(0)) { $0 + size($1) }
            let otherHome = max(0, tree.root.allocatedSize - homeAccounted)

            add("photos", "Photos Libraries", "photo.stack.fill", photos, "Managed by Photos — clean up in Media Cleaner", .mediaCleaner)
            add("downloads", "Downloads", "arrow.down.circle.fill", downloads, "Installers, archives and other downloads", .largeFiles)
            add("app-data", "App Data", "folder.fill", appData, "Application Support and app containers", .leftovers)
            add("other-home", "Projects & Other Files", "folder.badge.gearshape", otherHome, "Everything else in your Home folder", .storageAnalyzer)
            add("xcode", "Xcode & Simulators", "hammer.fill", xcode, "DerivedData, Device Support, simulators", .developerCleanup)
            add("dev-caches", "Developer Caches", "terminal.fill", developerCaches, "npm, pnpm, Gradle, Android, Playwright…", .developerCleanup)
            add("app-caches", "App Caches", "shippingbox.fill", appCaches, "Rebuildable application caches", .applicationCache)
            add("documents", "Documents & Desktop", "doc.richtext.fill", documents, "Your files", .largeFiles)
            add("icloud", "iCloud Drive (downloaded)", "icloud.fill", iCloud, "Local copies of iCloud Drive files", nil)
            add("library-other", "Other Library Data", "books.vertical.fill", libraryOther, "Preferences, logs, mail and app state", .systemJunk)
            add("trash", "Trash", "trash.fill", trash, "Freed when the Trash is emptied", .trashManager)
        }
        if let applicationsBytes {
            add("applications", "Applications", "app.fill", applicationsBytes, "Apps in /Applications", .leftovers)
        }
        if let systemVolumeUsed {
            add("macos", "macOS", "apple.logo", systemVolumeUsed, "The sealed, read-only system volume", nil)
        }
        if let dataVolume {
            let measured = areas.filter { $0.id != "macos" }.reduce(Int64(0)) { $0 + $1.bytes }
            let used = dataVolume.usedBytes
            let remainder = max(0, used - measured - (systemVolumeUsed ?? 0))
            if remainder > 0 {
                var detail = "Not visible to CleanLocal: other users, system caches, swap, Homebrew (/opt), local snapshots"
                if let purgeable, purgeable > 0 { detail += ", plus \(purgeable.formattedBytes) macOS can purge on demand" }
                areas.append(StorageArea(id: "system-other", title: "System Data & Other", symbolName: "gearshape.2.fill",
                                         bytes: remainder, detail: detail, destination: .maintenance, isMeasured: false))
            }
        }
        return areas.sorted { $0.bytes > $1.bytes }
    }

    /// Used bytes on the sealed system volume ("/"), via `statfs`.
    static func systemVolumeUsedBytes() -> Int64? {
        var stats = statfs()
        guard statfs("/", &stats) == 0 else { return nil }
        return Int64(stats.f_blocks - stats.f_bfree) * Int64(stats.f_bsize)
    }
}

enum StorageScanPhase: Equatable {
    case idle
    case scanning(DiskScanProgress)
    case ready
    case failed(String)
}

/// Storage Analyzer, Large Files, Old Files and file duplicates share one disk scan.
@MainActor
@Observable
final class StorageStore {
    private(set) var tree: DiskTree?
    private(set) var phase: StorageScanPhase = .idle
    private(set) var areas: [StorageArea] = []
    private(set) var applicationsBytes: Int64?
    private(set) var duplicateGroups: [FileDuplicateGroup] = []
    private(set) var duplicatesPhase: AnalysisPhase = .notStarted
    /// Items removed since the last scan (hidden from views until the next scan).
    private(set) var removedPaths = Set<String>()
    var currentNodeID: Int?

    @ObservationIgnored private var pathIndex: [String: Int] = [:]
    @ObservationIgnored private let access: AccessStore
    @ObservationIgnored private let storage: StorageAnalyticsService
    @ObservationIgnored private let scanner = DiskUsageScanner()
    @ObservationIgnored private var scanTask: Task<Void, Never>?

    init(access: AccessStore, storage: StorageAnalyticsService) {
        self.access = access
        self.storage = storage
    }

    var isScanning: Bool {
        if case .scanning = phase { return true }
        return false
    }

    /// Recomputes the breakdown (works partially even before a Home scan).
    func refreshAreas() {
        areas = StorageBreakdownService.areas(
            tree: tree, pathIndex: pathIndex, homePath: access.homeURL?.path ?? UserDirectories.realHomePath,
            applicationsBytes: applicationsBytes, systemVolumeUsed: StorageBreakdownService.systemVolumeUsedBytes(),
            dataVolume: storage.startupVolume(), purgeable: SystemInfoService.snapshot().purgeableBytes
        )
    }

    @discardableResult
    func scan() -> Task<Void, Never>? {
        guard !isScanning, let home = access.homeURL else { return nil }
        phase = .scanning(DiskScanProgress())
        let scanner = self.scanner
        let task = Task { [weak self] in
            async let apps = Task.detached(priority: .utility) {
                InstalledAppsScanner.scan().reduce(Int64(0)) { total, app in
                    total + ((try? DirectorySizer.measure(app.url).allocatedSize) ?? 0)
                }
            }.value
            do {
                let tree = try await scanner.scan(root: home) { [weak self] progress in
                    Task { @MainActor [weak self] in
                        guard let self, self.isScanning else { return }
                        self.phase = .scanning(progress)
                    }
                }
                let applications = await apps
                guard let self else { return }
                self.tree = tree
                self.pathIndex = Dictionary(tree.nodes.filter { $0.kind != .smallFiles }.map { ($0.path, $0.id) }, uniquingKeysWith: { first, _ in first })
                self.applicationsBytes = applications
                self.removedPaths = []
                self.currentNodeID = tree.rootID
                self.duplicateGroups = []
                self.duplicatesPhase = .notStarted
                self.refreshAreas()
                self.phase = .ready
            } catch is CancellationError {
                self?.phase = self?.tree == nil ? .idle : .ready
            } catch {
                self?.phase = .failed(error.localizedDescription)
            }
        }
        scanTask = task
        return task
    }

    func cancelScan() { scanTask?.cancel() }

    // MARK: Queries

    var visibleFiles: [DiskNode] {
        (tree?.files ?? []).filter { !isRemoved($0.path) }
    }

    func isRemoved(_ path: String) -> Bool {
        removedPaths.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func children(of id: Int) -> [DiskNode] {
        (tree?.children(of: id) ?? []).filter { !isRemoved($0.path) }
    }

    func markRemoved(_ paths: [String]) {
        removedPaths.formUnion(paths)
        duplicateGroups = duplicateGroups.compactMap { group in
            var group = group
            group.files.removeAll { paths.contains($0.path) }
            return group.files.count > 1 ? group : nil
        }
    }

    /// Wraps analyzer nodes as user-file cleanup candidates (always "review", Trash only).
    func candidates(for nodes: [DiskNode]) -> [CleanupCandidate] {
        guard let home = access.homeURL else { return [] }
        let engine = SafetyPolicyEngine(homePath: home.path)
        return nodes.compactMap { node in
            guard node.isRemovableEntry, let info = FileSpaceInspector.inspect(path: node.path) else { return nil }
            let protection = engine.hardProtectionReason(for: node.path)
            return CleanupCandidate(
                id: node.path, url: URL(fileURLWithPath: node.path), categoryID: "user-file", displayName: node.name,
                detail: UserDirectories.abbreviate(path: (node.path as NSString).deletingLastPathComponent), scope: .item,
                safety: protection == nil ? .review : .protected, reasons: protection.map { [$0] } ?? ["Chosen by you."],
                owner: nil, isDirectory: info.isDirectory,
                size: DirectorySize(logicalSize: node.logicalSize, allocatedSize: node.allocatedSize, reclaimableSize: node.reclaimableSize,
                                    fileCount: max(node.fileCount, 1), directoryCount: info.isDirectory ? 1 : 0, newestModification: node.modified),
                identity: info.identity, rootPath: home.path
            )
        }
    }

    // MARK: Duplicates (all file types)

    func findDuplicates() {
        guard let tree else { return }
        let files = tree.files.filter { !$0.path.contains("/Library/") && !isRemoved($0.path) }
        duplicatesPhase = .running(progress: 0, message: "Comparing \(files.count.formatted()) files…")
        Task { [weak self] in
            do {
                let groups = try await FileDuplicateFinder.find(in: files) { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.duplicatesPhase.isRunning else { return }
                        self.duplicatesPhase = .running(progress: fraction, message: "Verifying with SHA-256…")
                    }
                }
                self?.duplicateGroups = groups
                self?.duplicatesPhase = .completed(.now)
            } catch {
                self?.duplicatesPhase = .failed(error.localizedDescription)
            }
        }
    }
}

/// Read-only system facts for the Maintenance screen.
@MainActor
@Observable
final class MaintenanceStore {
    private(set) var snapshot: SystemSnapshot?
    private(set) var launchItems: [LaunchItem] = []
    private(set) var unreadableLaunchFolders: [String] = []
    private(set) var isLoading = false

    @ObservationIgnored private let access: AccessStore

    init(access: AccessStore) {
        self.access = access
    }

    func refresh() async {
        isLoading = true
        let home = access.homeURL ?? UserDirectories.realHomeURL
        let (snapshot, launch) = await Task.detached(priority: .userInitiated) {
            (SystemInfoService.snapshot(), LoginItemsService.launchItems(home: home))
        }.value
        self.snapshot = snapshot
        launchItems = launch.items
        unreadableLaunchFolders = launch.unreadable
        access.refreshAudit()
        isLoading = false
    }
}
