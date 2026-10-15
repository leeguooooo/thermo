import Darwin
import Foundation

/// Directory walking with `getattrlistbulk(2)`: one call returns a whole batch of entries with
/// their attributes, instead of one `lstat` per file. It also returns each file's *private* size
/// (ATTR_CMNEXT_PRIVATESIZE): the blocks only that file owns. On APFS, clones and snapshots share
/// blocks, so a folder of 58 Chrome code-sign clones "uses" 81 GB but deleting it frees almost
/// nothing; the private size is what removal actually gives back.
enum BulkWalk {
    /// What we ask for, in the order the kernel packs it (common attrs by bit, file attrs, then
    /// the extended common attrs). With FSOPT_PACK_INVAL_ATTRS every field is always present.
    static func attrList() -> attrlist {
        var a = attrlist()
        a.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        a.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS) | attrgroup_t(ATTR_CMN_NAME) | attrgroup_t(ATTR_CMN_ERROR)
            | attrgroup_t(ATTR_CMN_OBJTYPE) | attrgroup_t(ATTR_CMN_MODTIME) | attrgroup_t(ATTR_CMN_CHGTIME)
            | attrgroup_t(ATTR_CMN_FILEID)
        a.fileattr = attrgroup_t(ATTR_FILE_LINKCOUNT) | attrgroup_t(ATTR_FILE_ALLOCSIZE)
        // Private size is costly for every file; `size` asks for it per large file instead, and
        // only when the extended flags say the file may share blocks (a clone).
        a.forkattr = attrgroup_t(ATTR_CMNEXT_EXT_FLAGS)
        return a
    }

    static let options = UInt64(FSOPT_NOFOLLOW) | UInt64(FSOPT_PACK_INVAL_ATTRS) | UInt64(FSOPT_ATTR_CMN_EXTENDED)

    struct Entry {
        var name: String
        var isDir: Bool
        var isFile: Bool
        var modified: Int
        var modifiedNanoseconds: Int = 0
        /// Status change time: set when a file is moved, renamed, extracted or re-permissioned, so a
        /// download unpacked today with an old mtime is not mistaken for something untouched.
        var changed: Int = 0
        var fileID: UInt64
        var links: UInt32
        var allocated: Int64
        var privateSize: Int64
        var error: Int32
        /// EF_* flags; nil when the file system did not return them.
        var extFlags: UInt64? = nil

        /// Its blocks may be shared with another file (an APFS clone): only then can the private
        /// size be smaller than the allocated size. Unknown counts as maybe.
        var maySharesBlocks: Bool { extFlags.map { $0 & UInt64(EF_MAY_SHARE_BLOCKS) != 0 } ?? true }
    }

    /// Calls `body` for every entry of `dir` (not recursive). Returns false if it can't be read.
    @discardableResult
    static func entries(of dir: String, cancellation: ScanCancellation? = nil, shouldStop: (() -> Bool)? = nil, _ body: (Entry) -> Void) -> Bool {
        let cancellation = cancellation ?? ScanCancellation.current
        let fd = open(dir, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var list = attrList()
        let bufSize = 256 * 1024
        let buf = UnsafeMutableRawPointer.allocate(byteCount: bufSize, alignment: 8)
        defer { buf.deallocate() }
        while true {
            // Checked per batch, so a huge flat folder stops promptly too.
            if cancellation?.isCancelled == true || shouldStop?() == true { return true }
            let n = getattrlistbulk(fd, &list, buf, bufSize, options)
            if n < 0 { return false }
            if n == 0 { return true }
            var p = buf
            for _ in 0..<n {
                if cancellation?.isCancelled == true || shouldStop?() == true { return true }
                let len = Int(p.loadUnaligned(as: UInt32.self))
                var q = p + 4
                // attribute_set_t: which attributes are valid for this entry.
                let returned = q.loadUnaligned(as: attribute_set_t.self)
                q += MemoryLayout<attribute_set_t>.size
                let error = q.loadUnaligned(as: UInt32.self); q += 4
                let nameRef = q.loadUnaligned(as: attrreference_t.self)
                let name = String(cString: (q + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: CChar.self))
                q += MemoryLayout<attrreference_t>.size
                let type = q.loadUnaligned(as: UInt32.self); q += 4
                let mod = q.loadUnaligned(as: timespec.self); q += MemoryLayout<timespec>.size
                let chg = q.loadUnaligned(as: timespec.self); q += MemoryLayout<timespec>.size
                let fileID = q.loadUnaligned(as: UInt64.self); q += 8
                // File attributes are packed (zero-filled) for every entry because of PACK_INVAL.
                let links = q.loadUnaligned(as: UInt32.self); q += 4
                let alloc = q.loadUnaligned(as: Int64.self); q += 8
                let flags = q.loadUnaligned(as: UInt64.self)
                let hasFlags = returned.forkattr & attrgroup_t(ATTR_CMNEXT_EXT_FLAGS) != 0
                body(Entry(name: name, isDir: type == VDIR.rawValue, isFile: type == VREG.rawValue,
                           modified: mod.tv_sec, modifiedNanoseconds: mod.tv_nsec, changed: chg.tv_sec, fileID: fileID, links: links, allocated: alloc,
                           privateSize: alloc, error: Int32(bitPattern: error), extFlags: hasFlags ? flags : nil))
                p += len
            }
        }
    }

    /// Files this large get their private (unshared) size looked up; smaller ones count as
    /// allocated. Nearly all reclaimable space sits in large files, and they are few.
    static let privateSizeThreshold: Int64 = 512 * 1024

    /// Sizes one tree without following symlinks or leaving the volume. Nil when the volume does
    /// not support getattrlistbulk (the caller falls back to fts).
    ///
    /// Reclaimable bytes: a hard-linked file only counts when all its links are inside the tree
    /// (pnpm and bun link node_modules to a global store, so deleting node_modules frees nothing);
    /// a large file counts only its private blocks (APFS clones share theirs).
    static func size(_ root: String, trackNewest: Bool, device: dev_t, cancellation: ScanCancellation? = nil, privateSizes: Bool = true, maxEntries: Int? = nil) -> TreeSize? {
        let cancellation = cancellation ?? ScanCancellation.current
        var r = TreeSize()
        var linked: [UInt64: (links: UInt32, seen: UInt32, bytes: Int64)] = [:]
        var stack = [root]
        var newest = 0
        var visited = 0
        var entriesSeen = 0
        var stopped = false
        let changes = FS.countsStatusChanges
        while let dir = stack.popLast() {
            visited += 1
            if cancellation?.isCancelled == true || stopped { r.incomplete = true; break }
            let ok = entries(of: dir, cancellation: cancellation, shouldStop: { stopped }) { e in
                entriesSeen += 1
                if cancellation?.isCancelled == true || maxEntries.map({ entriesSeen > $0 }) == true { r.incomplete = true; stopped = true; return }
                if e.error != 0 {
                    r.incomplete = true
                    if e.error == EACCES || e.error == EPERM { r.denied = true }
                    return
                }
                if e.isDir {
                    let child = dir + "/" + e.name
                    var st = stat()
                    // Stay on this volume (mounted disk images, network shares inside caches).
                    if lstat(child, &st) == 0 { if st.st_dev == device { stack.append(child) } }
                    else { r.incomplete = true }
                    return
                }
                if e.links > 1 {
                    if var l = linked[e.fileID] { l.seen += 1; linked[e.fileID] = l; return }
                    linked[e.fileID] = (e.links, 1, e.allocated)
                    r.files += 1
                    r.allocated += e.allocated
                    return
                }
                r.files += 1
                r.allocated += e.allocated
                // A file that shares no blocks frees all it allocates; asking APFS costs ~2 ms a file.
                r.bytes += privateSizes && e.allocated >= privateSizeThreshold && e.maySharesBlocks
                    ? (fileSize(dir + "/" + e.name)?.privateSize ?? e.allocated) : e.allocated
                if trackNewest { newest = max(newest, e.modified, changes ? e.changed : 0) }
            }
            if !ok {
                let e = errno
                if dir == root, e == ENOTSUP || e == EINVAL { return nil }
                r.incomplete = true
                if e == EACCES || e == EPERM { r.denied = true }
            }
        }
        // Hard links whose every name lies inside this tree go with it.
        for l in linked.values where l.seen >= l.links { r.bytes += l.bytes }
        if trackNewest, newest > 0 { r.newest = Date(timeIntervalSince1970: TimeInterval(newest)) }
        return r
    }

    /// Private and allocated size of a single file.
    static func fileSize(_ path: String) -> (allocated: Int64, privateSize: Int64)? {
        var list = attrList()
        list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
        list.fileattr = attrgroup_t(ATTR_FILE_ALLOCSIZE)
        list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
        var buf = [UInt8](repeating: 0, count: 64)
        let rc = getattrlist(path, &list, &buf, buf.count, UInt32(options))
        guard rc == 0 else { return nil }
        return buf.withUnsafeBytes { raw in
            var q = raw.baseAddress! + 4
            let returned = q.loadUnaligned(as: attribute_set_t.self)
            q += MemoryLayout<attribute_set_t>.size
            let alloc = q.loadUnaligned(as: Int64.self); q += 8
            let priv = q.loadUnaligned(as: Int64.self)
            return (alloc, returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 ? priv : alloc)
        }
    }
}
