import AppKit
import ExtensionFoundation
import ExtensionKit
import ModuleKit
import ModuleSDK
import PreviewCore
import QuickLookUI
import SwiftUI
import ThermoL10n

private final class PreviewPreparation: @unchecked Sendable {
    static let shared = PreviewPreparation()
    private let lock = NSLock()
    private var current: UUID?
    private let root = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-search-preview-"+UUID().uuidString, isDirectory:true)
    func accepts(_ id:UUID) -> Bool { lock.lock();defer{lock.unlock()};return current == id }
    func prepare(_ file:FileHandle?, metadata:Data) async throws -> Data {
        let input=try PreviewInput.decode(metadata)
        if input.kind == .retire {
            guard file == nil else { throw PreviewFailure.invalidInput }
            await retire()
            return try JSONSerialization.data(withJSONObject:["input":input.id.uuidString,"retired":true])
        }
        lock.lock();current=input.id;lock.unlock()
        let cache=PreviewInputCache(root:root)
        let url=try await Task.detached(priority:.userInitiated) {
            try cache.prepare(input,file:file,cancelled:{ !self.accepts(input.id) })
        }.value
        try await MainActor.run {
            guard self.accepts(input.id) else { throw PreviewFailure.cancelled }
            PreviewModel.shared.input=input;PreviewModel.shared.url=url
        }
        return try JSONSerialization.data(withJSONObject:["input":input.id.uuidString,"prepared":true,"pid":Int(getpid())])
    }
    func retire() async {
        lock.lock();current=nil;lock.unlock()
        await MainActor.run {
            PreviewModel.shared.retire()
        }
        try? FileManager.default.removeItem(at:root)
    }
}

@MainActor private final class PreviewModel:ObservableObject {
    static let shared=PreviewModel()
    @Published var input:PreviewInput?
    @Published var url:URL?
    private var views:[ObjectIdentifier:PreviewContainer]=[:]
    func attach(_ view:PreviewContainer) { views[ObjectIdentifier(view)]=view }
    func detach(_ view:PreviewContainer) { views[ObjectIdentifier(view)]=nil;view.close() }
    func retire() {
        for view in views.values { view.close() }
        views.removeAll();input=nil;url=nil
    }
}

/// Returning a container keeps SwiftUI from applying its own QLPreviewView teardown.
@MainActor private final class PreviewContainer:NSView {
    private let preview:QLPreviewView
    private var closed=false
    init(url:URL) {
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
    func makeNSView(context:Context) -> PreviewContainer {
        let view=PreviewContainer(url:url);PreviewModel.shared.attach(view);return view
    }
    func updateNSView(_ view:PreviewContainer,context:Context) { view.update(url) }
    static func dismantleNSView(_ view:PreviewContainer,coordinator:()) { PreviewModel.shared.detach(view) }
}

private struct SearchPreviewView:View {
    @ObservedObject var model=PreviewModel.shared
    var body:some View {
        Group {
            if let input=model.input {
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
                    } else if let url=model.url {
                        PreviewSurface(url:url).id(input.id)
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
