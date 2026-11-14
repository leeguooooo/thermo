import Darwin
import Foundation

/// Coordinates native CLI commands with the App's feature switches. Kernel file
/// locks disappear with their owner; no process is signalled or terminated.
public final class ModuleCommandLease: @unchecked Sendable {
    public enum Failure: Error, LocalizedError {
        case off(String), busy(String), unsafeLocation, io(Int32)
        public var errorDescription: String? {
            switch self {
            case .off(let id): return "\(id) is switched off."
            case .busy(let id): return "\(id) has a command in progress or is stopping."
            case .unsafeLocation: return "The feature command directory is not a private, directly owned location."
            case .io(let code): return String(cString:strerror(code))
            }
        }
    }
    private let lock=NSLock()
    private var admission:Int32
    private var reader:Int32
    private var blocking:Int32
    private init(admission:Int32,reader:Int32,blocking:Int32) {
        self.admission=admission;self.reader=reader;self.blocking=blocking
    }
    deinit {closeDescriptors()}
    private func closeDescriptors() {
        lock.lock();defer{lock.unlock()}
        for descriptor in [blocking,reader,admission] where descriptor>=0 {Darwin.close(descriptor)}
        blocking = -1;reader = -1;admission = -1
    }
    public var stopRequested:Bool {
        lock.lock();defer{lock.unlock()}
        guard admission>=0 else{return true}
        guard flock(admission,LOCK_SH|LOCK_NB)==0 else{return true}
        _=flock(admission,LOCK_UN);return false
    }
    public static func begin(feature:String,interruptible:Bool=false,home:String=NSHomeDirectory(),
                             enabled:()->Bool) throws -> ModuleCommandLease {
        guard ModuleManifest.matches(ModuleManifest.identifier,feature) else{throw Failure.unsafeLocation}
        let folder=try directory(home:home);defer{Darwin.close(folder)}
        let admission=try file(folder:folder,feature:feature,suffix:"admission")
        var reader:Int32 = -1,blocking:Int32 = -1,keep=false
        defer{if !keep {for descriptor in [blocking,reader,admission] where descriptor>=0 {Darwin.close(descriptor)}}}
        guard flock(admission,LOCK_SH|LOCK_NB)==0 else{throw Failure.busy(feature)}
        guard enabled() else{throw Failure.off(feature)}
        reader=try file(folder:folder,feature:feature,suffix:"readers")
        guard flock(reader,LOCK_SH|LOCK_NB)==0 else{throw Failure.busy(feature)}
        if !interruptible {
            blocking=try file(folder:folder,feature:feature,suffix:"blocking")
            guard flock(blocking,LOCK_SH|LOCK_NB)==0 else{throw Failure.busy(feature)}
        }
        guard flock(admission,LOCK_UN)==0 else{throw Failure.io(errno)}
        keep=true;return .init(admission:admission,reader:reader,blocking:blocking)
    }
    public final class Quiescence: @unchecked Sendable {
        private let lock=NSLock()
        private var admission:Int32,reader:Int32,blocking:Int32
        fileprivate init(admission:Int32,reader:Int32,blocking:Int32) {
            self.admission=admission;self.reader=reader;self.blocking=blocking
        }
        deinit{release()}
        public var readersFinished:Bool {
            lock.lock();defer{lock.unlock()}
            guard reader>=0 else{return true}
            return flock(reader,LOCK_EX|LOCK_NB)==0
        }
        public func waitForReaders() async {
            while !readersFinished {try? await Task.sleep(nanoseconds:50_000_000)}
        }
        public func release() {
            lock.lock();defer{lock.unlock()}
            for descriptor in [reader,blocking,admission] where descriptor>=0 {Darwin.close(descriptor)}
            reader = -1;blocking = -1;admission = -1
        }
    }
    public static func quiesce(feature:String,home:String=NSHomeDirectory()) throws -> Quiescence {
        guard ModuleManifest.matches(ModuleManifest.identifier,feature) else{throw Failure.unsafeLocation}
        let folder=try directory(home:home);defer{Darwin.close(folder)}
        let admission=try file(folder:folder,feature:feature,suffix:"admission")
        var reader:Int32 = -1,blocking:Int32 = -1,keep=false
        defer{if !keep {for descriptor in [reader,blocking,admission] where descriptor>=0 {Darwin.close(descriptor)}}}
        guard flock(admission,LOCK_EX|LOCK_NB)==0 else{throw Failure.busy(feature)}
        blocking=try file(folder:folder,feature:feature,suffix:"blocking")
        guard flock(blocking,LOCK_EX|LOCK_NB)==0 else{throw Failure.busy(feature)}
        reader=try file(folder:folder,feature:feature,suffix:"readers")
        keep=true;return .init(admission:admission,reader:reader,blocking:blocking)
    }
    private static func file(folder:Int32,feature:String,suffix:String) throws -> Int32 {
        guard ModuleManifest.matches(ModuleManifest.identifier,feature) else{throw Failure.unsafeLocation}
        let descriptor=openat(folder,feature+"."+suffix,O_RDWR|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0o600)
        guard descriptor>=0 else{throw Failure.io(errno)}
        var value=stat()
        guard fstat(descriptor,&value)==0,value.st_mode&S_IFMT==S_IFREG,value.st_uid==getuid(),
              value.st_nlink==1,value.st_mode&0o022==0 else{Darwin.close(descriptor);throw Failure.unsafeLocation}
        return descriptor
    }
    private static func directory(home:String) throws -> Int32 {
        guard home.hasPrefix("/"),let physical=realpath(home,nil) else{throw Failure.unsafeLocation}
        let root=String(cString:physical);free(physical)
        var descriptor=open(root,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
        guard descriptor>=0 else{throw Failure.io(errno)}
        do {
            for component in ["Library","Application Support","Thermo","command-leases"] {
                if mkdirat(descriptor,component,0o700)<0,errno != EEXIST {throw Failure.io(errno)}
                let next=openat(descriptor,component,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW)
                guard next>=0 else{throw Failure.unsafeLocation}
                Darwin.close(descriptor);descriptor=next
                var value=stat()
                guard fstat(descriptor,&value)==0,value.st_uid==getuid(),value.st_mode&0o022==0 else{throw Failure.unsafeLocation}
            }
            return descriptor
        } catch {Darwin.close(descriptor);throw error}
    }
}
