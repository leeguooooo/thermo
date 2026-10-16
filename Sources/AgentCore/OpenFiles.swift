import Darwin
import Foundation

/// Files and folders the user's processes hold open right now (open file descriptors and working
/// directories), read with `proc_pidinfo` instead of `lsof`, which takes minutes on a cache tree.
public struct OpenFiles: Sendable {
    public struct Holder: Sendable {
        public var path: String
        public var pid: pid_t
        public var name: String
    }

    /// Sorted by path.
    public let holders: [Holder]

    public init(holders: [Holder]) { self.holders = holders.sorted { $0.path < $1.path } }

    public struct Observation: Codable, Sendable {
        public var paths: [String]
        /// Completeness of cwd/vnode-FD queries only; does not include memory mappings.
        public var complete: Bool
        public var truncated: Bool
        public init(paths: [String], complete: Bool, truncated: Bool = false) {
            self.paths = paths; self.complete = complete; self.truncated = truncated
        }
    }

    /// Bounded diagnostic reader. Unlike cleanup's inventory, no process names are ignored.
    public static func observe(_ pid: pid_t, maximumDescriptors: Int = 4096, maximumPaths: Int = 100) -> Observation {
        var result = Observation(paths: [], complete: true)
        guard maximumDescriptors > 0, maximumDescriptors <= 65_536, maximumPaths > 0 else {
            return .init(paths: [], complete: false, truncated: true)
        }
        var vpi = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            let path = string(vpi.pvi_cdir.vip_path)
            if !path.isEmpty { result.paths.append(path) }
        } else { result.complete = false }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { result.complete = false; return result }
        let stride = MemoryLayout<proc_fdinfo>.stride
        let count = min(maximumDescriptors, Int(bytes) / stride + 16)
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let capacity = count * stride
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { result.complete = false; return result }
        if Int(got) >= capacity || Int(bytes) > capacity { result.complete = false; result.truncated = true }
        for fd in fds.prefix(min(count, Int(got) / stride)) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else {
                result.complete = false; continue
            }
            let path = string(info.pvip.vip_path)
            if !path.isEmpty { result.paths.append(path) }
        }
        result.paths = Array(Set(result.paths)).sorted()
        if result.paths.count > maximumPaths {
            result.paths = Array(result.paths.prefix(maximumPaths)); result.complete = false; result.truncated = true
        }
        return result
    }

    /// Indexers and other system helpers that open files briefly while looking at them.
    static let ignored: Set<String> = ["mdworker", "mdworker_shared", "mds_stores", "mdwrite", "fseventsd", "lsd", "revisiond"]

    /// Nil when the process list itself could not be read; processes the kernel refuses are skipped.
    public static func current(uid: uid_t = getuid()) -> OpenFiles? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: uid)]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        size += size / 8
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, UInt32(mib.count), &procs, &size, nil, 0) == 0 else { return nil }
        let me = getpid()
        var out: [Holder] = []
        for k in procs.prefix(size / MemoryLayout<kinfo_proc>.stride) {
            let pid = k.kp_proc.p_pid
            guard pid > 0, pid != me else { continue }
            let name = withUnsafeBytes(of: k.kp_proc.p_comm) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
            if ignored.contains(name) { continue }
            for path in openPaths(pid) { out.append(Holder(path: path, pid: pid, name: name)) }
        }
        return OpenFiles(holders: out)
    }

    /// The working directory and every open vnode of one process.
    static func openPaths(_ pid: pid_t) -> [String] {
        var paths: [String] = []
        var vpi = proc_vnodepathinfo()
        if proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vpi, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 {
            let cwd = string(vpi.pvi_cdir.vip_path)
            if !cwd.isEmpty { paths.append(cwd) }
        }
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return paths }
        let stride = MemoryLayout<proc_fdinfo>.stride
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / stride + 16)
        let got = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        guard got > 0 else { return paths }
        for fd in fds.prefix(Int(got) / stride) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var info = vnode_fdinfowithpath()
            let n = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size))
            guard n > 0 else { continue }
            let p = string(info.pvip.vip_path)
            if !p.isEmpty { paths.append(p) }
        }
        return paths
    }

    private static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
    }

    /// A process holding `path` itself or anything inside it open. `path` is resolved first:
    /// the kernel reports real paths (`/private/var/…`).
    public func holder(of path: String) -> Holder? {
        // realpath, not URL.resolvingSymlinksInPath: that one maps /private/var back to /var.
        let target = realpath(path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? path
        var lo = 0, hi = holders.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if holders[mid].path < target { lo = mid + 1 } else { hi = mid }
        }
        var i = lo
        while i < holders.count, holders[i].path.hasPrefix(target) {
            let p = holders[i].path
            if p == target || p.dropFirst(target.count).first == "/" { return holders[i] }
            i += 1
        }
        return nil
    }
}

/// Which file a path names: device and inode, so a path swapped for another file since a scan is caught.
public enum FileIdentity {
    public static func of(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return "\(st.st_dev):\(st.st_ino)"
    }
}
