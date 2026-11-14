import AppKit
import ExtensionFoundation
import ExtensionKit
import ModuleKit
import ModuleSDK
import PreviewCore
import PreviewUI
import QuickLookUI
import SwiftUI
import ThermoL10n

private final class PreviewPreparation: @unchecked Sendable {
    static let shared = PreviewPreparation()
    private struct Pending { let input:PreviewInput;let file:URL?;var assets:[String:URL];let expected:Set<String> }
    private let lock = NSLock()
    private var current: UUID?
    private var pending: Pending?
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-preview-"+UUID().uuidString,isDirectory:true)
    func accepts(_ id:UUID) -> Bool { lock.lock();defer{lock.unlock()};return current == id }
    private func begin(_ id:UUID) { lock.lock();current=id;pending=nil;lock.unlock() }
    private func save(_ value:Pending) throws { lock.lock();defer{lock.unlock()};guard current == value.input.id else{throw PreviewFailure.cancelled};pending=value }
    private func snapshot(_ id:UUID) throws -> Pending { lock.lock();defer{lock.unlock()};guard current == id,let pending else{throw PreviewFailure.cancelled};return pending }
    private func saveAsset(_ url:URL,resource:String,id:UUID) throws { lock.lock();defer{lock.unlock()};guard current == id,pending?.expected.contains(resource) == true else{throw PreviewFailure.cancelled};pending?.assets[resource]=url }
    private func receipt(_ id:UUID,ready:Bool,assets:[String]=[]) throws -> Data {
        try JSONSerialization.data(withJSONObject:["input":id.uuidString,"ready":ready,"needsAssets":assets,"pid":Int(getpid())])
    }
    private func document(_ value:Pending,collect:(([String])->Void)?=nil) throws -> PreviewMarkdownDocument {
        guard let file=value.file else{throw PreviewFailure.invalidInput}
        let base=value.input.originalURL.flatMap(URL.init(string:))?.deletingLastPathComponent()
        var missing:[String]=[]
        let doc=try PreviewMarkdownDocument.load(file,baseURL:base,readImage:{url,limit in
            if let local=value.assets[url.absoluteString],let handle=try? FileHandle(forReadingFrom:local) {
                defer{try? handle.close()}
                return try? handle.read(upToCount:limit+1)
            }
            if missing.count<48,!missing.contains(url.absoluteString){missing.append(url.absoluteString)}
            return nil
        })
        collect?(missing);return doc
    }
    private func publish(_ value:Pending,markdown:PreviewMarkdownDocument?) async throws {
        try await MainActor.run {
            guard self.accepts(value.input.id) else{throw PreviewFailure.cancelled}
            if let language=value.input.language { L10n.apply(preference:language) }
            PreviewModel.shared.markdown=markdown;PreviewModel.shared.url=value.file;PreviewModel.shared.input=value.input
        }
    }
    func prepare(_ file:FileHandle?,metadata:Data) async throws -> Data {
        let input=try PreviewInput.decode(metadata)
        if input.kind == .retire {guard file == nil else{throw PreviewFailure.invalidInput};await retire(input.id);return try receipt(input.id,ready:false)}
        if input.kind == .asset {
            let value=try snapshot(input.id)
            guard let resource=input.resourceURL,value.expected.contains(resource) else{throw PreviewFailure.invalidInput}
            let url=try await Task.detached(priority:.userInitiated){try PreviewInputCache(root:self.root.appendingPathComponent(input.id.uuidString)).prepare(input,file:file,cancelled:{!self.accepts(input.id)})}.value
            guard let url else{throw PreviewFailure.invalidInput}
            try saveAsset(url,resource:resource,id:input.id)
            return try receipt(input.id,ready:false)
        }
        if input.kind == .render {
            guard file == nil else{throw PreviewFailure.invalidInput}
            let value=try snapshot(input.id)
            let markdown=try await Task.detached(priority:.userInitiated){try self.document(value)}.value
            try await publish(value,markdown:markdown);return try receipt(input.id,ready:true)
        }
        begin(input.id)
        let url=try await Task.detached(priority:.userInitiated){try PreviewInputCache(root:self.root.appendingPathComponent(input.id.uuidString)).prepare(input,file:file,cancelled:{!self.accepts(input.id)})}.value
        var value=Pending(input:input,file:url,assets:[:],expected:[])
        if let url,PreviewMarkdownDocument.supports(url) {
            let initial=value
            let (markdown,needed)=try await Task.detached(priority:.userInitiated){
                var urls:[String]=[]
                let document=try self.document(initial,collect:{urls=$0})
                return (document,urls)
            }.value
            value=Pending(input:input,file:url,assets:[:],expected:Set(needed));try save(value)
            if needed.isEmpty {try await publish(value,markdown:markdown)}
            return try receipt(input.id,ready:needed.isEmpty,assets:needed)
        }
        try save(value);try await publish(value,markdown:nil);return try receipt(input.id,ready:true)
    }
    func retire(_ id:UUID) async {
        retireState(id)
        await MainActor.run {PreviewModel.shared.retire(id)}
        try? FileManager.default.removeItem(at:root.appendingPathComponent(id.uuidString))
    }
    private func retireState(_ id:UUID) {
        lock.lock();defer{lock.unlock()}
        if current == id {current=nil}
        if pending?.input.id == id {pending=nil}
    }
}

@MainActor private final class PreviewModel:ObservableObject {
    static let shared=PreviewModel()
    @Published var input:PreviewInput?
    @Published var url:URL?
    @Published var markdown:PreviewMarkdownDocument?
    private var views:[ObjectIdentifier:PreviewContainer]=[:]
    func attach(_ view:PreviewContainer) { views[ObjectIdentifier(view)]=view }
    func detach(_ view:PreviewContainer) { views[ObjectIdentifier(view)]=nil;view.close() }
    struct Snapshot {let input:PreviewInput;let url:URL?;let markdown:PreviewMarkdownDocument?}
    var snapshot:Snapshot? {input.map {Snapshot(input:$0,url:url,markdown:markdown)}}
    func retire(_ id:UUID) {
        for view in Array(views.values) where view.inputID == id {detach(view)}
        if input?.id == id {input=nil;url=nil;markdown=nil}
    }
}

/// Returning a container keeps SwiftUI from applying its own QLPreviewView teardown.
@MainActor private final class PreviewContainer:NSView {
    let inputID:UUID
    private let preview:QLPreviewView
    private var closed=false
    init(url:URL,id:UUID) {
        inputID=id
        preview=QLPreviewView(frame:.zero,style:.normal)
        super.init(frame:.zero)
        preview.autostarts=true;preview.translatesAutoresizingMaskIntoConstraints=false
        addSubview(preview)
        NSLayoutConstraint.activate([preview.leadingAnchor.constraint(equalTo:leadingAnchor),preview.trailingAnchor.constraint(equalTo:trailingAnchor),
            preview.topAnchor.constraint(equalTo:topAnchor),preview.bottomAnchor.constraint(equalTo:bottomAnchor)])
        preview.previewItem=url as NSURL
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    func update(_ url:URL) { guard !closed else{return};preview.previewItem=url as NSURL }
    func close() { guard !closed else{return};closed=true;preview.previewItem=nil;preview.close() }
}

private struct PreviewSurface:NSViewRepresentable {
    let url:URL
    let id:UUID
    func makeNSView(context:Context) -> PreviewContainer {
        let view=PreviewContainer(url:url,id:id);PreviewModel.shared.attach(view);return view
    }
    func updateNSView(_ view:PreviewContainer,context:Context) { view.update(url) }
    static func dismantleNSView(_ view:PreviewContainer,coordinator:()) { PreviewModel.shared.detach(view) }
}

private struct SearchPreviewView:View {
    private let model=PreviewModel.shared.snapshot
    var body:some View {
        Group {
            if let model {
                let input=model.input
                VStack(alignment:.leading,spacing:12) {
                    Text(input.name).font(.headline).textSelection(.enabled)
                    if input.kind == .directory {
                        List(Array(input.entries.enumerated()),id:\.offset) { _,entry in
                            HStack {
                                Image(systemName:entry.directory ? "folder":"doc")
                                Text(entry.name).textSelection(.enabled)
                                Spacer()
                                if let bytes=entry.bytes { Text(ByteCountFormatter.string(fromByteCount:bytes,countStyle:.file)).foregroundStyle(.secondary) }
                            }
                        }
                    } else if let markdown=model.markdown {
                        MarkdownPreviewPane(document:markdown).id(input.id)
                    } else if let url=model.url {
                        PreviewSurface(url:url,id:input.id).id(input.id)
                    } else { Text(tr("Nothing to preview.")) }
                }.padding(16)
            } else { Text(tr("Preparing preview…")).foregroundStyle(.secondary) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity).preferredColorScheme(.dark)
    }
}

@main struct SearchPreview:AppExtension {
    init() {
        let runtime=ModuleRuntime.shared
        runtime.fileInput { file,metadata in try await PreviewPreparation.shared.prepare(file,metadata:metadata) }
    }
    var configuration:AppExtensionSceneConfiguration {
        AppExtensionSceneConfiguration(moduleScene("preview") { SearchPreviewView() }, configuration:ModuleConfiguration())
    }
}
