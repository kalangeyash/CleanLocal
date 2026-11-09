import Darwin
import Foundation

/// Precise disk-space facts for one filesystem entry.
///
/// Logical size is what Finder shows as "Size". Allocated size is the blocks actually used.
/// On APFS, clones share blocks and hard links share an inode, so neither tells you what
/// deleting a file frees. ``reclaimableSize`` combines the APFS *private size* (blocks used
/// only by this file) with the hard-link count to give a conservative answer.
struct FileSpaceInfo: Hashable, Sendable {
    var logicalSize: Int64
    var allocatedSize: Int64
    /// Bytes not shared with any clone (APFS only). `nil` on other filesystems.
    var privateSize: Int64?
    /// Identifier shared by files cloned from each other (APFS only).
    var cloneID: UInt64?
    /// Every block of this file is shared with at least one clone.
    var sharesAllBlocks: Bool
    /// Some blocks may be shared with a clone.
    var maySharesBlocks: Bool
    var linkCount: Int
    var device: Int64
    var inode: UInt64
    var isRegularFile: Bool
    var isDirectory: Bool
    var isSymbolicLink: Bool
    var isImmutable: Bool
    var modificationDate: Date

    /// What removing this single entry would free right now.
    ///
    /// * Hard-linked files free nothing until every link is gone.
    /// * Clones free only their private blocks.
    var reclaimableSize: Int64 {
        guard isRegularFile else { return 0 }
        if linkCount > 1 { return 0 }
        if let privateSize {
            return allocatedSize > 0 ? min(max(privateSize, 0), allocatedSize) : max(privateSize, 0)
        }
        return allocatedSize
    }

    var isClone: Bool { sharesAllBlocks || maySharesBlocks }

    /// Stable identity used to detect a file being replaced between scan and cleanup.
    var identity: FileIdentity { FileIdentity(device: device, inode: inode) }
}

struct FileIdentity: Hashable, Codable, Sendable {
    let device: Int64
    let inode: UInt64
}

enum FileSpaceInspector {
    // From <sys/attr.h>; declared here so the meaning is explicit.
    private static let extFlagMaySharesBlocks: UInt64 = 0x0000_0001
    private static let extFlagSharesAllBlocks: UInt64 = 0x0000_0040

    /// Inspects `path` without following a final symbolic link.
    static func inspect(path: String) -> FileSpaceInfo? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let type = st.st_mode & S_IFMT
        var info = FileSpaceInfo(
            logicalSize: Int64(st.st_size),
            allocatedSize: Int64(st.st_blocks) * 512,
            privateSize: nil,
            cloneID: nil,
            sharesAllBlocks: false,
            maySharesBlocks: false,
            linkCount: Int(st.st_nlink),
            device: Int64(st.st_dev),
            inode: UInt64(st.st_ino),
            isRegularFile: type == S_IFREG,
            isDirectory: type == S_IFDIR,
            isSymbolicLink: type == S_IFLNK,
            isImmutable: (st.st_flags & UInt32(UF_IMMUTABLE)) != 0 || (st.st_flags & UInt32(SF_IMMUTABLE)) != 0,
            modificationDate: Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9)
        )
        if info.isRegularFile { readCloneAttributes(path: path, into: &info) }
        return info
    }

    static func inspect(url: URL) -> FileSpaceInfo? { inspect(path: url.path) }

    /// Reads APFS private size, clone ID and extended flags with `getattrlist(2)`.
    private static func readCloneAttributes(path: String, into info: inout FileSpaceInfo) {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        request.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_CLONEID | ATTR_CMNEXT_EXT_FLAGS)

        var buffer = [UInt8](repeating: 0, count: 128)
        let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
        let result = buffer.withUnsafeMutableBytes { raw in
            getattrlist(path, &request, raw.baseAddress, raw.count, options)
        }
        guard result == 0 else { return }

        buffer.withUnsafeBytes { raw in
            var offset = MemoryLayout<UInt32>.size // total length
            let returned = raw.loadUnaligned(fromByteOffset: offset, as: attribute_set_t.self)
            offset += MemoryLayout<attribute_set_t>.size
            // Attributes are packed in ascending bit order.
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 {
                info.privateSize = raw.loadUnaligned(fromByteOffset: offset, as: Int64.self)
                offset += MemoryLayout<Int64>.size
            }
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_CLONEID) != 0 {
                let cloneID = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                info.cloneID = cloneID == 0 ? nil : cloneID
                offset += MemoryLayout<UInt64>.size
            }
            if returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0 {
                let flags = raw.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
                info.sharesAllBlocks = flags & extFlagSharesAllBlocks != 0
                info.maySharesBlocks = flags & extFlagMaySharesBlocks != 0
            }
        }
    }
}

/// Aggregated size of a directory tree.
struct DirectorySize: Hashable, Sendable {
    var logicalSize: Int64 = 0
    var allocatedSize: Int64 = 0
    var reclaimableSize: Int64 = 0
    var fileCount = 0
    var directoryCount = 0
    var newestModification: Date?

    static func + (lhs: DirectorySize, rhs: DirectorySize) -> DirectorySize {
        DirectorySize(
            logicalSize: lhs.logicalSize + rhs.logicalSize,
            allocatedSize: lhs.allocatedSize + rhs.allocatedSize,
            reclaimableSize: lhs.reclaimableSize + rhs.reclaimableSize,
            fileCount: lhs.fileCount + rhs.fileCount,
            directoryCount: lhs.directoryCount + rhs.directoryCount,
            newestModification: [lhs.newestModification, rhs.newestModification].compactMap { $0 }.max()
        )
    }
}

enum DirectorySizer {
    /// Measures a file or directory tree without following symbolic links or crossing
    /// onto other volumes. Hard-linked files are counted once.
    ///
    /// - Parameter filter: Return `false` to exclude a child entry (and its subtree).
    static func measure(
        _ url: URL,
        filter: ((URL, FileSpaceInfo) -> Bool)? = nil
    ) throws -> DirectorySize {
        guard let root = FileSpaceInspector.inspect(url: url) else {
            throw CleanLocalError.fileNotFound(path: url.path)
        }
        var total = DirectorySize()
        var seenLinked = Set<FileIdentity>()

        func add(_ info: FileSpaceInfo) {
            if info.isDirectory {
                total.directoryCount += 1
                return
            }
            if info.linkCount > 1 {
                guard seenLinked.insert(info.identity).inserted else { return }
            }
            total.fileCount += 1
            total.logicalSize += info.logicalSize
            total.allocatedSize += info.allocatedSize
            total.reclaimableSize += info.reclaimableSize
            if total.newestModification.map({ info.modificationDate > $0 }) ?? true {
                total.newestModification = info.modificationDate
            }
        }

        guard root.isDirectory else {
            add(root)
            return total
        }

        var stack = [url]
        while let directory = stack.popLast() {
            if Task.isCancelled { throw CancellationError() }
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { continue }
            for name in names {
                let child = directory.appendingPathComponent(name)
                guard let info = FileSpaceInspector.inspect(url: child), !info.isSymbolicLink else { continue }
                if info.device != root.device { continue } // never cross mount points
                if let filter, !filter(child, info) { continue }
                add(info)
                if info.isDirectory { stack.append(child) }
            }
        }
        return total
    }
}
