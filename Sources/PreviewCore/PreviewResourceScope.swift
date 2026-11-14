import Darwin
import Foundation

/// A kernel-owned directory handle. A renderer's resource request cannot follow links outside it.
public final class PreviewResourceScope: @unchecked Sendable {
    public let root:URL
    private let directory:FileHandle
    private let aliases:[String]
    public init(root:URL) throws {
        guard let resolved=realpath(root.path,nil) else{throw PreviewFailure.copyFailed(errno)}
        let physical=String(cString:resolved);free(resolved)
        self.root=URL(fileURLWithPath:physical,isDirectory:true)
        self.aliases=Array(Set([physical,root.path,root.resolvingSymlinksInPath().path])).sorted{$0.count > $1.count}
        var descriptor=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard descriptor>=0 else{throw PreviewFailure.copyFailed(errno)}
        do {
            for component in physical.split(separator:"/").map(String.init) {
                let next=openat(descriptor,component,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
                guard next>=0 else{throw PreviewFailure.copyFailed(errno)}
                close(descriptor);descriptor=next
            }
        }catch{close(descriptor);throw error}
        directory=FileHandle(fileDescriptor:descriptor,closeOnDealloc:true)
    }
    public func openFile(_ url:URL, imageOnly:Bool=false, maxBytes:Int64?=nil) throws -> FileHandle {
        guard url.isFileURL else{throw PreviewFailure.invalidInput}
        let path=url.path
        guard let base=aliases.first(where:{path.hasPrefix($0 == "/" ? "/" : $0+"/") && path != $0}) else{throw PreviewFailure.invalidInput}
        let prefix=base == "/" ? "/" : base+"/"
        var parts:[String]=[]
        for part in path.dropFirst(prefix.count).split(separator:"/",omittingEmptySubsequences:false).map(String.init) {
            guard !part.isEmpty,!part.utf8.contains(0) else{throw PreviewFailure.invalidInput}
            if part == "."{continue}
            if part == ".."{guard !parts.isEmpty else{throw PreviewFailure.invalidInput};parts.removeLast()}
            else{parts.append(part)}
        }
        guard !parts.isEmpty else{throw PreviewFailure.invalidInput}
        if imageOnly,!Set(["png","jpg","jpeg","gif","webp","svg"]).contains(url.pathExtension.lowercased()){throw PreviewFailure.invalidInput}
        var descriptor=dup(directory.fileDescriptor)
        guard descriptor>=0 else{throw PreviewFailure.copyFailed(errno)}
        defer{close(descriptor)}
        for component in parts.dropLast() {
            let next=openat(descriptor,component,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
            guard next>=0 else{throw PreviewFailure.copyFailed(errno)}
            close(descriptor);descriptor=next
        }
        let file=openat(descriptor,parts.last!,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
        guard file>=0 else{throw PreviewFailure.copyFailed(errno)}
        var info=stat()
        guard fstat(file,&info)==0,info.st_mode & S_IFMT == S_IFREG,info.st_size>=0,
              maxBytes.map({info.st_size <= $0}) ?? true else{close(file);throw PreviewFailure.readOnlyFileRequired}
        return FileHandle(fileDescriptor:file,closeOnDealloc:true)
    }
}
