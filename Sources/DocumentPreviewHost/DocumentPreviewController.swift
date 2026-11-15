import DocumentPreviewAPI
import Combine
import ModuleKernelCore
import AppKit
import Darwin
import ModuleHost
import ModuleKit
import PreviewCore
import SearchCore
import SwiftUI
import ThermoL10n

private struct DocumentPreviewSource: @unchecked Sendable {
    let input:PreviewInput
    let file:FileHandle?
    let scope:PreviewResourceScope?
    static func open(_ item:SelectedDocument,id:UUID,roots:[String],language:String,sequence:UInt64,cancelled:@Sendable()->Bool) throws -> Self {
        if cancelled(){throw PreviewFailure.cancelled}
        let url=URL(fileURLWithPath:item.path).resolvingSymlinksInPath().standardizedFileURL
        if item.kind == .directory {
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
            return .init(input:.init(id:id,kind:.directory,name:item.name,entries:entries,originalURL:url.absoluteString,language:language,sequence:sequence),file:nil,scope:nil)
        }
        let allowed=roots.map(SearchPaths.canonical).filter{SearchPaths.isWithin(url.path,root:$0)}.max{$0.count < $1.count}
        let scope=try PreviewResourceScope(root:allowed.map{URL(fileURLWithPath:$0,isDirectory:true)} ?? url.deletingLastPathComponent())
        let file=try scope.openFile(url)
        return .init(input:.init(id:id,kind:.file,name:item.name,originalURL:url.absoluteString,language:language,sequence:sequence),file:file,scope:scope)
    }
}

@MainActor final class DocumentPreviewController:ObservableObject,DocumentPreviewPresentation {
    enum State:Equatable {case idle,preparing,ready(UUID),failed(String)}
    @Published private(set) var state=State.idle
    let broker:DocumentPreviewBroker
    private let available:@MainActor ()->Bool
    private var manager:ModuleManager{broker.manager}
    var worker:String{broker.worker}
    private var current:UUID?
    private var currentSequence:UInt64?
    private var cancellation:SearchCancellation?
    private var tasks:[UUID:Task<Void,Never>]=[:]
    private var cleanups:[UUID:Task<Void,Never>]=[:]
    init(broker:DocumentPreviewBroker,available:@escaping @MainActor ()->Bool){self.broker=broker;self.available=available}
    private func owns(_ id:UUID)->Bool{available() && current == id && broker.owner == id}
    func canAttach(_ id:UUID)->Bool{state == .ready(id) && owns(id)}
    func content(selection:SelectedDocument,roots:[String],request:UUID)->AnyView {
        AnyView(DocumentPreviewPane(preview:self,selection:selection,roots:roots,request:request).id(request))
    }
    func open(_ item:SelectedDocument,roots:[String],request:UUID = UUID()) {
        guard available() else{state = .failed(tr("This feature is switched off."));return}
        if let issue=broker.restartRequired(){state = .failed(issue);return}
        if current == request{return}
        guard broker.sequence < UInt64.max else{state = .failed(tr("File preview stopped. Try previewing the file again."));return}
        stop()
        let id=request,cancel=SearchCancellation();current=id;broker.owner=id;cancellation=cancel;state = .preparing
        broker.sequence += 1;let sequence=broker.sequence;currentSequence=sequence
        let language=L10n.current.rawValue
        let task=Task{[weak self] in
            defer{self?.tasks[id]=nil}
            do {
                let source=try await Task.detached(priority:.userInitiated){try DocumentPreviewSource.open(item,id:id,roots:roots,language:language,sequence:sequence,cancelled:{cancel.isCancelled})}.value
                defer{try? source.file?.close()}
                try Task.checkCancellation();guard let self,self.owns(id) else{throw PreviewFailure.cancelled}
                let deadline=Date().addingTimeInterval(10)
                while !broker.loaded(),Date()<deadline{try await Task.sleep(nanoseconds:20_000_000)}
                guard broker.loaded() else{throw PreviewFailure.invalidInput}
                manager.setEnabled(worker,true)
                let first=try await manager.prepareInput(worker,file:source.file,metadata:source.input.data(),timeout:30)
                try Task.checkCancellation();guard owns(id) else{throw PreviewFailure.cancelled}
                let receipt=try Self.receipt(first,id:id)
                ModuleKernel.log.record(ModuleAccessRecord(module:worker,capability:Capability.Kind.filesRead.rawValue,operation:"selected-input",targets:[item.path],outcome:.allowed,detail:"Read-only input supplied for this selected preview; no filesystem scope granted."))
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
                            let input=PreviewInput(id:id,kind:.asset,name:url.lastPathComponent,resourceURL:name,sequence:sequence)
                            _=try await manager.prepareInput(worker,file:file,metadata:input.data(),timeout:15)
                            ModuleKernel.log.record(ModuleAccessRecord(module:worker,capability:Capability.Kind.filesRead.rawValue,operation:"preview-resource",targets:[url.path],outcome:.allowed,detail:"Read-only associated image supplied within the selected preview scope."))
                        }
                    }
                    let final=try await manager.prepareInput(worker,file:nil,metadata:PreviewInput(id:id,kind:.render,name:source.input.name,sequence:sequence).data(),timeout:30)
                    guard try Self.receipt(final,id:id)["ready"] as? Bool == true else{throw PreviewFailure.invalidInput}
                }
                try Task.checkCancellation();guard owns(id) else{throw PreviewFailure.cancelled}
                state = .ready(id)
            }catch {
                guard let self,self.owns(id),!Task.isCancelled else{return}
                ModuleKernel.log.record(ModuleAccessRecord(module:worker,capability:Capability.Kind.filesRead.rawValue,operation:"selected-input",targets:[item.path],outcome:.failed,detail:error.localizedDescription))
                state = .failed((error as? ModuleError).map(String.init(describing:)) ?? error.localizedDescription);manager.setEnabled(worker,false)
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
        guard manager.modules.first(where:{$0.manifest.id == worker})?.phase == .running else {
            state = .failed(tr("File preview stopped. Try previewing the file again."));manager.setEnabled(worker,false);return
        }
    }
    func stop(ifCurrent expected:UUID? = nil) {
        if let expected,current != expected{return}
        cancellation?.cancel();for task in tasks.values{task.cancel()}
        if let id=current,broker.owner == id {
            broker.owner=nil
            let cleanupID=UUID(),sequence=currentSequence
            let cleanup=Task{[self] in
                defer{cleanups[cleanupID]=nil}
                if manager.modules.first(where:{$0.manifest.id == worker})?.phase == .running {
                    let input=PreviewInput(id:id,kind:.retire,name:"Preview",sequence:sequence)
                    _=try? await manager.prepareInput(worker,file:nil,metadata:input.data(),timeout:3)
                }
                if broker.owner == nil{manager.setEnabled(worker,false)}
            }
            cleanups[cleanupID]=cleanup
        }
        current=nil;currentSequence=nil;state = .idle
    }
    func finishStopping() async {
        for task in Array(tasks.values){await task.value}
        for task in Array(cleanups.values){await task.value}
    }
}
