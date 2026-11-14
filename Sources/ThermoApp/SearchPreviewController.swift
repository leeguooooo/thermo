import AppKit
import Darwin
import ModuleHost
import ModuleKit
import PreviewCore
import SearchCore
import SwiftUI
import ThermoL10n

private struct SearchPreviewSource: @unchecked Sendable {
    let input:PreviewInput
    let file:FileHandle?
    let scope:PreviewResourceScope?
    static func open(_ item:SearchItem,id:UUID,roots:[String],language:String,cancelled:@Sendable()->Bool) throws -> Self {
        if cancelled(){throw PreviewFailure.cancelled}
        let url=URL(fileURLWithPath:item.path).resolvingSymlinksInPath().standardizedFileURL
        if item.kind == .folder {
            let descriptor=Darwin.open(url.path,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK)
            guard descriptor>=0 else{throw PreviewFailure.copyFailed(errno)}
            guard let directory=fdopendir(descriptor) else{close(descriptor);throw PreviewFailure.copyFailed(errno)}
            defer{closedir(directory)}
            var entries:[PreviewInput.Entry]=[]
            while let entry=readdir(directory),entries.count<256 {
                if cancelled(){throw PreviewFailure.cancelled}
                let name=withUnsafeBytes(of:entry.pointee.d_name){String(decoding:$0.prefix(Int(entry.pointee.d_namlen)),as:UTF8.self)}
                if name == "." || name == ".."{continue}
                var info=stat();let known=fstatat(dirfd(directory),name,&info,AT_SYMLINK_NOFOLLOW)==0
                entries.append(.init(name:name,directory:known && info.st_mode & S_IFMT == S_IFDIR,bytes:known && info.st_mode & S_IFMT == S_IFREG ? info.st_size:nil))
            }
            return .init(input:.init(id:id,kind:.directory,name:item.name,entries:entries,originalURL:url.absoluteString,language:language),file:nil,scope:nil)
        }
        let allowed=roots.map(SearchPaths.canonical).filter{SearchPaths.isWithin(url.path,root:$0)}.max{$0.count < $1.count}
        let scope=try PreviewResourceScope(root:allowed.map{URL(fileURLWithPath:$0,isDirectory:true)} ?? url.deletingLastPathComponent())
        let file=try scope.openFile(url)
        return .init(input:.init(id:id,kind:.file,name:item.name,originalURL:url.absoluteString,language:language),file:file,scope:scope)
    }
}

@MainActor final class SearchPreviewController:ObservableObject {
    static let shared=SearchPreviewController()
    enum State:Equatable {case idle,preparing,ready(UUID),failed(String)}
    @Published private(set) var state=State.idle
    private static var owners:[ObjectIdentifier:UUID]=[:]
    let center:ModuleCenter
    let worker:String
    private var current:UUID?
    private var cancellation:SearchCancellation?
    private var tasks:[UUID:Task<Void,Never>]=[:]
    private var cleanups:[UUID:Task<Void,Never>]=[:]
    init(center:ModuleCenter = .shared,worker:String = SearchModule.previewWorker){self.center=center;self.worker=worker}
    private var key:ObjectIdentifier{ObjectIdentifier(center.manager)}
    private func owns(_ id:UUID)->Bool{current == id && Self.owners[key] == id}
    func open(_ item:SearchItem,roots:[String],request:UUID = UUID()) {
        guard SearchModule.enabled else{state = .failed(tr("This feature is switched off."));return}
        AppInstallationMonitor.shared.check()
        guard !AppInstallationMonitor.shared.needsRestart else{state = .failed(tr("An update is installed. Restart Thermo to use it."));return}
        stop()
        let id=request,cancel=SearchCancellation();current=id;Self.owners[key]=id;cancellation=cancel;state = .preparing
        let language=L10n.current.rawValue
        let task=Task{[weak self] in
            defer{self?.tasks[id]=nil}
            do {
                let source=try await Task.detached(priority:.userInitiated){try SearchPreviewSource.open(item,id:id,roots:roots,language:language,cancelled:{cancel.isCancelled})}.value
                defer{try? source.file?.close()}
                try Task.checkCancellation();guard let self,self.owns(id) else{throw PreviewFailure.cancelled}
                let deadline=Date().addingTimeInterval(10)
                while !center.loaded,Date()<deadline{try await Task.sleep(nanoseconds:20_000_000)}
                guard center.loaded else{throw PreviewFailure.invalidInput}
                center.manager.setEnabled(worker,true)
                let first=try await center.manager.prepareInput(worker,file:source.file,metadata:source.input.data(),timeout:30)
                try Task.checkCancellation();guard owns(id) else{throw PreviewFailure.cancelled}
                let receipt=try Self.receipt(first,id:id)
                let assets=receipt["needsAssets"] as? [String] ?? []
                guard assets.count<=48 else{throw PreviewFailure.invalidInput}
                if receipt["ready"] as? Bool != true {
                    var bytes:Int64=0
                    if let scope=source.scope {
                        for name in assets {
                            try Task.checkCancellation();guard owns(id) else{throw PreviewFailure.cancelled}
                            guard let url=URL(string:name),url.isFileURL else{continue}
                            let file:FileHandle
                            do { file=try await Task.detached(priority:.userInitiated,operation:{try scope.openFile(url,imageOnly:true,maxBytes:8*1024*1024)}).value }
                            catch {
                                ModuleKernel.log.record(ModuleAccessRecord(module:worker,capability:Capability.Kind.filesRead.rawValue,operation:"preview-resource",targets:[url.path],outcome:.denied,detail:"Resource outside the selected preview scope or not a bounded regular image."))
                                continue
                            }
                            defer{try? file.close()}
                            var info=stat();guard fstat(file.fileDescriptor,&info)==0,bytes+info.st_size<=24*1024*1024 else{continue}
                            bytes += info.st_size
                            let input=PreviewInput(id:id,kind:.asset,name:url.lastPathComponent,resourceURL:name)
                            _=try await center.manager.prepareInput(worker,file:file,metadata:input.data(),timeout:15)
                            ModuleKernel.log.record(ModuleAccessRecord(module:worker,capability:Capability.Kind.filesRead.rawValue,operation:"preview-resource",targets:[url.path],outcome:.allowed,detail:"Read-only associated image supplied within the selected preview scope."))
                        }
                    }
                    let final=try await center.manager.prepareInput(worker,file:nil,metadata:PreviewInput(id:id,kind:.render,name:source.input.name).data(),timeout:30)
                    guard try Self.receipt(final,id:id)["ready"] as? Bool == true else{throw PreviewFailure.invalidInput}
                }
                try Task.checkCancellation();guard owns(id) else{throw PreviewFailure.cancelled}
                ModuleKernel.log.record(ModuleAccessRecord(module:worker,capability:Capability.Kind.filesRead.rawValue,operation:"selected-input",targets:[item.path],outcome:.allowed,detail:"Read-only input supplied for this selected preview; no filesystem scope granted."))
                state = .ready(id)
            }catch {
                guard let self,self.owns(id),!Task.isCancelled else{return}
                state = .failed((error as? ModuleError).map(String.init(describing:)) ?? error.localizedDescription);center.manager.setEnabled(worker,false)
            }
        }
        tasks[id]=task
    }
    private static func receipt(_ data:Data,id:UUID) throws -> [String:Any] {
        guard let value=try JSONSerialization.jsonObject(with:data) as? [String:Any],value["input"] as? String == id.uuidString else{throw PreviewFailure.invalidInput}
        return value
    }
    func observeStatus() {
        guard case let .ready(id)=state,owns(id) else{return}
        guard center.statuses.first(where:{$0.manifest.id == worker})?.phase == .running else {
            state = .failed(tr("File preview stopped. Try previewing the file again."));center.manager.setEnabled(worker,false);return
        }
    }
    func stop(ifCurrent expected:UUID? = nil) {
        if let expected,current != expected{return}
        cancellation?.cancel();for task in tasks.values{task.cancel()}
        if let id=current,Self.owners[key] == id {
            Self.owners[key]=nil
            let cleanupID=UUID(),owner=key
            let cleanup=Task{[self] in
                defer{cleanups[cleanupID]=nil}
                if center.statuses.first(where:{$0.manifest.id == worker})?.phase == .running {
                    let input=PreviewInput(id:id,kind:.retire,name:"Preview")
                    _=try? await center.manager.prepareInput(worker,file:nil,metadata:input.data(),timeout:3)
                }
                if Self.owners[owner] == nil{center.manager.setEnabled(worker,false)}
            }
            cleanups[cleanupID]=cleanup
        }
        current=nil;state = .idle
    }
    func finishStopping() async {
        for task in Array(tasks.values){await task.value}
        for task in Array(cleanups.values){await task.value}
    }
}
