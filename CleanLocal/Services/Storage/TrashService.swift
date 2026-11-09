import Foundation
import OSLog

/// One top-level item in a Trash folder.
struct TrashEntry: Identifiable, Hashable, Sendable {
    var id: String { url.path }
    let url: URL
    let name: String
    let size: DirectorySize
    let isDirectory: Bool
    /// When the item was put in the Trash (the date it was added to the Trash folder).
    let dateTrashed: Date?
    /// The Trash folder containing it (`~/.Trash` or `/Volumes/X/.Trashes/<uid>`).
    let trashRoot: String
    /// Original location, when CleanLocal moved it there itself.
    var originalPath: String?
}

struct TrashRemovalResult: Sendable {
    let path: String
    let freedBytes: Int64
    let error: String?
}

/// Lists and permanently empties Trash folders the user granted access to.
///
/// macOS protects the Trash, so CleanLocal can only see it after the user grants access in
/// an open panel. Removal is limited to *direct children* of a Trash folder, and every
/// item is re-checked immediately before it's removed.
actor TrashService {
    private let remover: any FileRemoving

    init(remover: any FileRemoving = SystemFileRemover()) {
        self.remover = remover
    }

    /// Trash folders for the user's home and for granted external volumes.
    nonisolated static func trashFolders(homeTrash: URL?, volumeRoots: [URL]) -> [URL] {
        var folders: [URL] = []
        if let homeTrash { folders.append(homeTrash) }
        let uid = getuid()
        for volume in volumeRoots {
            let trash = volume.appendingPathComponent(".Trashes/\(uid)")
            if FileManager.default.fileExists(atPath: trash.path) { folders.append(trash) }
        }
        return folders
    }

    func entries(in trashFolders: [URL], originalPaths: [String: String] = [:]) -> (entries: [TrashEntry], issues: [AccessIssue]) {
        var entries: [TrashEntry] = []
        var issues: [AccessIssue] = []
        for folder in trashFolders {
            let names: [String]
            do {
                names = try FileManager.default.contentsOfDirectory(atPath: folder.path)
            } catch {
                issues.append(AccessIssue(path: folder.path, reason: "macOS didn’t allow CleanLocal to read this Trash folder."))
                continue
            }
            for name in names where name != ".DS_Store" && name != ".localized" {
                let url = folder.appendingPathComponent(name)
                guard let info = FileSpaceInspector.inspect(url: url) else { continue }
                let size = info.isSymbolicLink ? DirectorySize() : ((try? DirectorySizer.measure(url)) ?? DirectorySize())
                let added = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey]).addedToDirectoryDate
                entries.append(TrashEntry(url: url, name: name, size: size, isDirectory: info.isDirectory,
                                          dateTrashed: added, trashRoot: folder.path, originalPath: originalPaths[url.path]))
            }
        }
        return (entries.sorted { $0.size.allocatedSize > $1.size.allocatedSize }, issues)
    }

    /// Permanently removes the given Trash entries.
    func permanentlyDelete(_ entries: [TrashEntry]) -> [TrashRemovalResult] {
        entries.map { entry in deleteFromTrash(path: entry.url.path, trashRoot: entry.trashRoot) }
    }

    /// Permanently removes items CleanLocal itself moved to the Trash ("free space now").
    func deleteTrashedItems(_ paths: [String]) -> [TrashRemovalResult] {
        paths.map { path in
            let parent = (path as NSString).deletingLastPathComponent
            guard Self.isTrashFolder(parent) else {
                return TrashRemovalResult(path: path, freedBytes: 0, error: "Not inside a Trash folder.")
            }
            return deleteFromTrash(path: path, trashRoot: parent)
        }
    }

    /// `~/.Trash` or `/Volumes/<name>/.Trashes/<uid>`.
    nonisolated static func isTrashFolder(_ path: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        if standardized.hasSuffix("/.Trash") { return true }
        let parent = (standardized as NSString).deletingLastPathComponent
        return parent.hasSuffix("/.Trashes")
    }

    private func deleteFromTrash(path: String, trashRoot: String) -> TrashRemovalResult {
        let standardized = (path as NSString).standardizingPath
        guard Self.isTrashFolder(trashRoot),
              (standardized as NSString).deletingLastPathComponent == (trashRoot as NSString).standardizingPath else {
            return TrashRemovalResult(path: path, freedBytes: 0, error: "Only items directly inside the Trash can be emptied.")
        }
        guard let info = FileSpaceInspector.inspect(path: standardized) else {
            return TrashRemovalResult(path: path, freedBytes: 0, error: "Already gone from the Trash.")
        }
        if info.isImmutable {
            return TrashRemovalResult(path: path, freedBytes: 0, error: "Locked in Finder.")
        }
        // Symbolic links are removed as links; their targets are never touched.
        let freed = info.isSymbolicLink ? 0 : ((try? DirectorySizer.measure(URL(fileURLWithPath: standardized)).reclaimableSize) ?? 0)
        do {
            try remover.deletePermanently(URL(fileURLWithPath: standardized))
            return TrashRemovalResult(path: path, freedBytes: freed, error: nil)
        } catch {
            return TrashRemovalResult(path: path, freedBytes: 0, error: SafeDeletionService.map(error, path: path).localizedDescription)
        }
    }
}
