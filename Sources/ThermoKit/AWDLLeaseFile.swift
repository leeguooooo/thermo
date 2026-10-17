import Darwin
import Foundation

/// Fixed leaf names in a protected directory. A lifetime flock excludes another
/// controller, and an existing recovery record is never overwritten.
public final class AWDLLeaseFile {
    private let directory: String
    private let owner: uid_t
    private let leaf="dev.thermo.awdl-lease"
    private let lockLeaf="dev.thermo.awdl-lock"
    private var lockFD: Int32 = -1
    private var recordIdentity: stat?
    public init(directory: String = "/Library/Application Support/dev.thermo",owner: uid_t = 0) { self.directory=directory;self.owner=owner }
    deinit { if lockFD >= 0 { close(lockFD) } }
    public var io: AWDLLeaseIO { .init(load:{ try self.load() },save:{ try self.save($0) },clear:{ try self.clear($0) }) }

    /// Preserve legacy recovery evidence: an old journal blocks a new lease,
    /// while an already-owned modern journal can still be restored and cleared.
    public static func systemStore() -> AWDLLeaseIO {
        systemStore(parentPath: "/Library/Application Support",
                    legacyRecord: "/private/var/run/dev.thermo.awdl-lease", owner: 0)
    }
    static func systemStore(parentPath: String, legacyRecord: String, owner: uid_t) -> AWDLLeaseIO {
        let file = AWDLLeaseFile(directory: parentPath + "/dev.thermo", owner: owner)
        func noLegacyRecord() throws {
            var info = stat()
            if lstat(legacyRecord, &info) == 0 { throw AWDLError("Legacy AWDL recovery record requires review before starting a new session") }
            guard errno == ENOENT else { throw AWDLError("Legacy AWDL recovery record could not be checked") }
        }
        return .init(load: {
            try ControlRecoveryDirectory.prepare(parentPath: parentPath, owner: owner)
            let record = try file.load()
            if record == nil { try noLegacyRecord() }
            return record
        }, save: {
            try ControlRecoveryDirectory.prepare(parentPath: parentPath, owner: owner)
            try noLegacyRecord()
            try file.save($0)
        }, clear: {
            try ControlRecoveryDirectory.prepare(parentPath: parentPath, owner: owner)
            try file.clear($0)
        })
    }

    private func failure(_ message: String) -> AWDLError { .init("AWDL lease: "+message) }
    private func protectedFile(_ s: stat) -> Bool {
        s.st_mode & S_IFMT == S_IFREG && s.st_uid == owner && s.st_nlink == 1 && s.st_mode & 0o7777 == 0o600
    }
    private func sameObject(_ a: stat,_ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_uid == b.st_uid && a.st_nlink == b.st_nlink }
    private func sameFile(_ a: stat,_ b: stat) -> Bool {
        sameObject(a,b) && a.st_size == b.st_size && a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    private func directoryStillNamed(_ fd: Int32) throws {
        var opened=stat(),named=stat()
        guard fstat(fd,&opened) == 0,lstat(directory,&named) == 0,
              opened.st_mode & S_IFMT == S_IFDIR,named.st_mode & S_IFMT == S_IFDIR,
              opened.st_uid == owner,named.st_uid == owner,opened.st_mode & 0o022 == 0,named.st_mode & 0o022 == 0,
              opened.st_dev == named.st_dev,opened.st_ino == named.st_ino else { throw failure("directory identity or permissions could not be verified") }
    }
    private func withDirectory<T>(_ action: (Int32) throws -> T) throws -> T {
        let fd=open(directory,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        guard fd >= 0 else { throw failure("cannot open protected directory") };defer { close(fd) }
        try directoryStillNamed(fd)
        if lockFD < 0 {
            let candidate=openat(fd,lockLeaf,O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,mode_t(0o600))
            guard candidate >= 0 else { throw failure("cannot open lock") }
            var info=stat()
            guard fstat(candidate,&info) == 0,protectedFile(info),flock(candidate,LOCK_EX|LOCK_NB) == 0 else {
                close(candidate);throw failure("lock is unsafe or another controller owns it")
            }
            lockFD=candidate
        }
        var held=stat(),named=stat()
        guard fstat(lockFD,&held) == 0,fstatat(fd,lockLeaf,&named,AT_SYMLINK_NOFOLLOW) == 0,
              protectedFile(held),sameObject(held,named) else { throw failure("lock identity changed") }
        let result=try action(fd)
        try directoryStillNamed(fd)
        return result
    }
    private final class Loaded {
        let value: AWDLRestoreRecord
        let identity: stat
        let fd: Int32
        init(_ value: AWDLRestoreRecord,_ identity: stat,_ fd: Int32) { self.value=value;self.identity=identity;self.fd=fd }
        deinit { close(fd) }
    }
    private func read(_ directoryFD: Int32) throws -> Loaded? {
        let fd=openat(directoryFD,leaf,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        if fd < 0 {
            if errno == ENOENT { return nil };throw failure("cannot open recovery record")
        }
        var transferred=false;defer { if !transferred { close(fd) } }
        var before=stat(),after=stat(),named=stat()
        guard fstat(fd,&before) == 0,protectedFile(before),before.st_size > 0,before.st_size <= 2048 else { throw failure("invalid record type, permissions or size") }
        var bytes=[UInt8](repeating:0,count:2049),total=0
        while total < bytes.count {
            let n=bytes.withUnsafeMutableBytes { Darwin.read(fd,$0.baseAddress!.advanced(by:total),$0.count-total) }
            if n < 0 { if errno == EINTR { continue };throw failure("cannot read record") }
            if n == 0 { break };total+=n
        }
        guard total == before.st_size,fstat(fd,&after) == 0,sameFile(before,after),
              fstatat(directoryFD,leaf,&named,AT_SYMLINK_NOFOLLOW) == 0,sameFile(after,named),
              let value=try? JSONDecoder().decode(AWDLRestoreRecord.self,from:Data(bytes.prefix(total))),value.valid else { throw failure("record changed or has an unsupported format") }
        transferred=true;return .init(value,after,fd)
    }
    public func load() throws -> AWDLRestoreRecord? {
        try withDirectory { fd in
            let loaded=try read(fd);recordIdentity=loaded?.identity;return loaded?.value
        }
    }
    public func save(_ value: AWDLRestoreRecord) throws {
        guard value.valid else { throw failure("invalid recovery value") }
        let data=try JSONEncoder().encode(value)
        try withDirectory { directoryFD in
            let fd=openat(directoryFD,leaf,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK,mode_t(0o600))
            guard fd >= 0 else { throw failure("record already exists or cannot be created") };defer { close(fd) }
            do {
                var info=stat();guard fstat(fd,&info) == 0,protectedFile(info) else { throw failure("new record identity is unsafe") }
                var offset=0
                while offset < data.count {
                    let count=data.withUnsafeBytes { Darwin.write(fd,$0.baseAddress!.advanced(by:offset),$0.count-offset) }
                    if count < 0,errno == EINTR { continue }
                    guard count > 0 else { throw failure("could not persist record") };offset+=count
                }
                guard fsync(fd) == 0,fsync(directoryFD) == 0 else { throw failure("could not sync recovery record") }
                var after=stat(),named=stat()
                guard fstat(fd,&after) == 0,protectedFile(after),fstatat(directoryFD,leaf,&named,AT_SYMLINK_NOFOLLOW) == 0,
                      sameFile(after,named) else { throw failure("new record changed") }
                try directoryStillNamed(directoryFD)
                recordIdentity=after
            } catch {
                var own=stat(),named=stat()
                if fstat(fd,&own) == 0,fstatat(directoryFD,leaf,&named,AT_SYMLINK_NOFOLLOW) == 0,sameObject(own,named) {
                    _=unlinkat(directoryFD,leaf,0);_=fsync(directoryFD)
                }
                throw error
            }
        }
    }
    public func clear(_ expected: AWDLRestoreRecord) throws {
        try withDirectory { directoryFD in
            guard let loaded=try read(directoryFD) else { recordIdentity=nil;return }
            var named=stat()
            guard let original=recordIdentity,sameFile(original,loaded.identity),loaded.value == expected,fstatat(directoryFD,leaf,&named,AT_SYMLINK_NOFOLLOW) == 0,
                  sameFile(loaded.identity,named) else { throw failure("recovery record was replaced") }
            guard unlinkat(directoryFD,leaf,0) == 0,fsync(directoryFD) == 0 else { throw failure("could not remove completed recovery record") }
            recordIdentity=nil
        }
    }
}
