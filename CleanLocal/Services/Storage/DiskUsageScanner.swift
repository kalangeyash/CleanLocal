import Foundation
import UniformTypeIdentifiers

/// Broad file types for the Large Files and Storage Analyzer views.
enum FileCategory: String, CaseIterable, Identifiable, Sendable, Hashable {
    case videos, images, audio, archives, installers, documents, developer, applications, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .videos: "Videos"
        case .images: "Images"
        case .audio: "Audio"
        case .archives: "Archives"
        case .installers: "Installers"
        case .documents: "Documents"
        case .developer: "Development"
        case .applications: "Applications"
        case .other: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .videos: "film.fill"
        case .images: "photo.fill"
        case .audio: "waveform"
        case .archives: "archivebox.fill"
        case .installers: "opticaldiscdrive.fill"
        case .documents: "doc.richtext.fill"
        case .developer: "hammer.fill"
        case .applications: "app.fill"
        case .other: "doc.fill"
        }
    }

    private static let developerComponents: Set<String> = [
        "node_modules", "DerivedData", ".gradle", ".build", "Pods", "target", ".npm", ".m2", "site-packages", "build",
    ]

    static func classify(path: String, isPackage: Bool) -> FileCategory {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        if ["dmg", "pkg", "mpkg", "iso", "xip"].contains(fileExtension) { return .installers }
        if ["zip", "gz", "tgz", "bz2", "xz", "7z", "rar", "tar"].contains(fileExtension) { return .archives }
        if fileExtension == "app" { return .applications }
        if path.split(separator: "/").contains(where: { developerComponents.contains(String($0)) }) { return .developer }
        if let type = UTType(filenameExtension: fileExtension) {
            if type.conforms(to: .movie) || type.conforms(to: .video) { return .videos }
            if type.conforms(to: .image) { return .images }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
                || type.conforms(to: .spreadsheet) || type.conforms(to: .epub) || ["doc", "docx", "pages", "key", "numbers"].contains(fileExtension) {
                return .documents
            }
        }
        if MediaFormat.from(fileExtension: fileExtension)?.kind == .video { return .videos }
        if MediaFormat.from(fileExtension: fileExtension)?.kind == .image { return .images }
        return isPackage ? .applications : .other
    }
}

/// A node in the disk-usage tree.
struct DiskNode: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case directory, package, file, smallFiles, inaccessible
    }

    let id: Int
    let name: String
    let path: String
    let kind: Kind
    var logicalSize: Int64
    var allocatedSize: Int64
    var reclaimableSize: Int64
    var fileCount: Int
    var modified: Date?
    var parent: Int?
    var children: [Int]
    var category: FileCategory

    var isContainer: Bool { kind == .directory }
    var isRemovableEntry: Bool { kind == .file || kind == .package || kind == .directory }
}

/// The result of analyzing one folder or volume.
struct DiskTree: Sendable {
    var nodes: [DiskNode]
    let rootID: Int
    let scannedAt: Date
    let inaccessibleCount: Int

    var root: DiskNode { nodes[rootID] }

    func node(_ id: Int) -> DiskNode { nodes[id] }

    /// Children sorted by allocated size, largest first.
    func children(of id: Int) -> [DiskNode] {
        nodes[id].children.map { nodes[$0] }.sorted { $0.allocatedSize > $1.allocatedSize }
    }

    /// Ancestors from the root to `id` inclusive.
    func breadcrumb(to id: Int) -> [DiskNode] {
        var chain: [DiskNode] = []
        var current: Int? = id
        while let index = current {
            chain.insert(nodes[index], at: 0)
            current = nodes[index].parent
        }
        return chain
    }

    /// Individual files and packages (never the "smaller files" aggregates).
    var files: [DiskNode] {
        nodes.filter { $0.kind == .file || $0.kind == .package }
    }
}

struct DiskScanProgress: Sendable, Equatable {
    var itemsVisited = 0
    var bytesCounted: Int64 = 0
    var currentPath = ""
}

/// Builds a size tree of a folder (DaisyDisk-style), counting real disk usage.
///
/// * Never follows symbolic links and never crosses onto another volume.
/// * Hard-linked files are counted once.
/// * Packages (apps, libraries) are sized but shown as single items.
/// * Files under `minimumFileSize` are aggregated per folder to keep memory bounded on
///   trees with hundreds of thousands of files.
actor DiskUsageScanner {
    static let packageExtensions: Set<String> = [
        "app", "framework", "bundle", "photoslibrary", "musiclibrary", "tvlibrary", "imovielibrary", "fcpbundle",
        "logicx", "xcarchive", "xcodeproj", "xcworkspace", "plugin", "kext", "appex", "pages", "key", "numbers",
        "rtfd", "sparsebundle", "dmgpart", "playground", "band", "lrlibrary", "lrdata", "photoslibrary",
    ]

    func scan(
        root: URL,
        minimumFileSize: Int64 = 1_000_000,
        progress: @escaping @Sendable (DiskScanProgress) -> Void = { _ in }
    ) async throws -> DiskTree {
        var builder = Builder(minimumFileSize: minimumFileSize, progress: progress)
        guard let rootInfo = FileSpaceInspector.inspect(url: root), rootInfo.isDirectory else {
            throw CleanLocalError.fileNotFound(path: root.path)
        }
        let rootID = try builder.visitDirectory(root, name: FileManager.default.displayName(atPath: root.path),
                                                parent: nil, device: rootInfo.device)
        return DiskTree(nodes: builder.nodes, rootID: rootID, scannedAt: .now, inaccessibleCount: builder.inaccessible)
    }

    private struct Builder {
        let minimumFileSize: Int64
        let progress: @Sendable (DiskScanProgress) -> Void
        var nodes: [DiskNode] = []
        var seenLinked = Set<FileIdentity>()
        var inaccessible = 0
        var state = DiskScanProgress()
        var throttle = ProgressThrottle(interval: .milliseconds(120))

        init(minimumFileSize: Int64, progress: @escaping @Sendable (DiskScanProgress) -> Void) {
            self.minimumFileSize = minimumFileSize
            self.progress = progress
        }

        mutating func append(_ node: DiskNode) -> Int {
            nodes.append(node)
            return nodes.count - 1
        }

        mutating func visitDirectory(_ url: URL, name: String, parent: Int?, device: Int64) throws -> Int {
            let id = append(DiskNode(id: nodes.count, name: name, path: url.path, kind: .directory, logicalSize: 0,
                                     allocatedSize: 0, reclaimableSize: 0, fileCount: 0, modified: nil, parent: parent,
                                     children: [], category: .other))
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: url.path) else {
                inaccessible += 1
                nodes[id] = DiskNode(id: id, name: name, path: url.path, kind: .inaccessible, logicalSize: 0, allocatedSize: 0,
                                     reclaimableSize: 0, fileCount: 0, modified: nil, parent: parent, children: [], category: .other)
                return id
            }

            var small = DirectorySize()
            for childName in names {
                if Task.isCancelled { throw CancellationError() }
                let child = url.appendingPathComponent(childName)
                guard let info = FileSpaceInspector.inspect(url: child), !info.isSymbolicLink, info.device == device else { continue }
                state.itemsVisited += 1

                if info.isDirectory {
                    let fileExtension = child.pathExtension.lowercased()
                    if !fileExtension.isEmpty, DiskUsageScanner.packageExtensions.contains(fileExtension) {
                        let size = (try? DirectorySizer.measure(child)) ?? DirectorySize()
                        let childID = append(DiskNode(id: nodes.count, name: childName, path: child.path, kind: .package,
                                                      logicalSize: size.logicalSize, allocatedSize: size.allocatedSize,
                                                      reclaimableSize: size.reclaimableSize, fileCount: size.fileCount,
                                                      modified: size.newestModification ?? info.modificationDate, parent: id, children: [],
                                                      category: FileCategory.classify(path: child.path, isPackage: true)))
                        nodes[id].children.append(childID)
                    } else {
                        let childID = try visitDirectory(child, name: childName, parent: id, device: device)
                        nodes[id].children.append(childID)
                    }
                    continue
                }

                // Count hard-linked files once.
                if info.linkCount > 1, !seenLinked.insert(info.identity).inserted { continue }
                state.bytesCounted += info.allocatedSize
                if info.logicalSize >= minimumFileSize {
                    let childID = append(DiskNode(id: nodes.count, name: childName, path: child.path, kind: .file,
                                                  logicalSize: info.logicalSize, allocatedSize: info.allocatedSize,
                                                  reclaimableSize: info.reclaimableSize, fileCount: 1, modified: info.modificationDate,
                                                  parent: id, children: [],
                                                  category: FileCategory.classify(path: child.path, isPackage: false)))
                    nodes[id].children.append(childID)
                } else {
                    small.logicalSize += info.logicalSize
                    small.allocatedSize += info.allocatedSize
                    small.reclaimableSize += info.linkCount > 1 ? 0 : info.allocatedSize
                    small.fileCount += 1
                }
                if throttle.shouldFire() {
                    state.currentPath = UserDirectories.abbreviate(path: url.path)
                    progress(state)
                }
            }

            if small.fileCount > 0 {
                let smallID = append(DiskNode(id: nodes.count, name: "\(small.fileCount.formatted()) smaller files", path: url.path,
                                              kind: .smallFiles, logicalSize: small.logicalSize, allocatedSize: small.allocatedSize,
                                              reclaimableSize: small.reclaimableSize, fileCount: small.fileCount, modified: nil,
                                              parent: id, children: [], category: .other))
                nodes[id].children.append(smallID)
            }

            // Roll child totals up into this folder.
            var logical: Int64 = 0, allocated: Int64 = 0, reclaimable: Int64 = 0, count = 0
            var newest: Date?
            for childID in nodes[id].children {
                let child = nodes[childID]
                logical += child.logicalSize
                allocated += child.allocatedSize
                reclaimable += child.reclaimableSize
                count += child.fileCount
                if let modified = child.modified, newest.map({ modified > $0 }) ?? true { newest = modified }
            }
            nodes[id].logicalSize = logical
            nodes[id].allocatedSize = allocated
            nodes[id].reclaimableSize = reclaimable
            nodes[id].fileCount = count
            nodes[id].modified = newest
            return id
        }
    }
}

/// Byte-identical files of any type, found in a disk-usage tree.
struct FileDuplicateGroup: Identifiable, Hashable, Sendable {
    let id: String
    var files: [DiskNode]
    var keeperPath: String
    /// What removing every copy except the keeper frees, accounting for clones and hard links.
    var reclaimableBytes: Int64
    /// The copies are APFS clones, so removing them frees little or nothing.
    var involvesClones: Bool
}

enum FileDuplicateFinder {
    /// Groups files ≥ `minimumSize` by size, then edge fingerprint, then SHA-256.
    static func find(
        in files: [DiskNode],
        minimumSize: Int64 = 1_000_000,
        maxConcurrency: Int = AppConstants.Scanning.hashingConcurrency,
        progress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [FileDuplicateGroup] {
        let candidates = Dictionary(grouping: files.filter { $0.kind == .file && $0.logicalSize >= minimumSize }) { $0.logicalSize }
            .values.filter { $0.count > 1 }.flatMap { $0 }

        let edges = try await candidates.concurrentMap(maxConcurrency: maxConcurrency) { node -> (DiskNode, String?) in
            (node, try? FileHasher.edgeFingerprint(of: URL(fileURLWithPath: node.path)))
        }
        let edgeGroups = Dictionary(grouping: edges.compactMap { pair in pair.1.map { (pair.0, "\(pair.0.logicalSize)|\($0)") } }) { $0.1 }
            .values.filter { $0.count > 1 }.flatMap { $0.map(\.0) }

        let total = Double(max(edgeGroups.count, 1))
        let counter = ProgressCounter()
        let hashed = try await edgeGroups.concurrentMap(maxConcurrency: maxConcurrency) { node -> (DiskNode, String?) in
            defer { progress(Double(counter.increment()) / total) }
            return (node, try? FileHasher.sha256(of: URL(fileURLWithPath: node.path)))
        }

        return Dictionary(grouping: hashed.compactMap { pair in pair.1.map { (pair.0, $0) } }) { $0.1 }
            .filter { $0.value.count > 1 }
            .map { hash, members in
                let nodes = members.map(\.0)
                let keeper = suggestedKeeper(nodes)
                let others = nodes.filter { $0.path != keeper.path }
                let keeperClone = FileSpaceInspector.inspect(path: keeper.path)?.cloneID
                var clones = false
                let reclaimable = others.reduce(Int64(0)) { total, node in
                    let info = FileSpaceInspector.inspect(path: node.path)
                    if let cloneID = info?.cloneID, cloneID == keeperClone { clones = true }
                    if info?.isClone == true { clones = true }
                    return total + (info?.reclaimableSize ?? node.reclaimableSize)
                }
                return FileDuplicateGroup(id: hash, files: [keeper] + others, keeperPath: keeper.path,
                                          reclaimableBytes: reclaimable, involvesClones: clones)
            }
            .sorted { $0.reclaimableBytes > $1.reclaimableBytes }
    }

    /// Keeps the copy outside Downloads/Desktop, without a "copy" marker, oldest, shortest path.
    static func suggestedKeeper(_ nodes: [DiskNode]) -> DiskNode {
        nodes.min { lhs, rhs in
            func score(_ node: DiskNode) -> (Int, Int, Date, Int) {
                let transient = ["/Downloads/", "/Desktop/"].contains { node.path.contains($0) } ? 1 : 0
                let copy = DuplicateSelectionPolicy.looksLikeCopy(node.name) ? 1 : 0
                return (transient, copy, node.modified ?? .distantFuture, node.path.count)
            }
            return score(lhs) < score(rhs)
        } ?? nodes[0]
    }
}
