import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n

@MainActor final class CaptureBatchImageExportModel:ObservableObject {
    @Published var allGroups=false
    @Published var selectedGroupID:UUID?
    @Published var format:CaptureSaveFormat = .png
    @Published var quality=0.9
    @Published private(set) var running=false
    @Published private(set) var cancelling=false
    @Published private(set) var completed=0
    @Published private(set) var total=0
    @Published private(set) var result:CaptureBatchImageResult?
    @Published private(set) var issue:String?
    private var task:Task<Void,Never>?
    private var operationID:UUID?
    deinit {task?.cancel()}
    func noteQuitBlocked() {issue=tr("Wait for the batch image export to finish, or cancel it before quitting.")}
    func itemsForExport(from session:CapturePinSession) throws -> [CaptureBatchImageItem] {
        try session.batchImageItems(group:allGroups ? nil : selectedGroupID ?? session.library.currentGroupID)
    }
    func report(_ error:Error) {issue=captureFailureMessage(error)}
    func start(_ items:[CaptureBatchImageItem],destination:URL,format:CaptureSaveFormat,quality:Double=0.9) {
        guard !running else{return}
        let id=UUID();operationID=id;running=true;cancelling=false;completed=0;total=items.count;result=nil;issue=nil
        let progress:@Sendable(Int,Int)->Void={ [weak self] count,_ in
            Task { @MainActor [weak self] in
                guard let self,self.operationID==id,self.running else{return};self.completed=max(self.completed,count)
            }
        }
        task=Task { [weak self] in
            let worker=Task.detached(priority:.userInitiated) {
                try CaptureBatchImageExport.run(items,in:destination,format:format,quality:quality,progress:progress)
            }
            do {
                let value=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
                guard let self,self.operationID==id else{return};self.result=value;self.completed=value.images.count;self.issue=nil
            } catch {
                guard let self,self.operationID==id else{return}
                self.issue=error is CancellationError ? tr("Batch image export cancelled.") : captureFailureMessage(error)
            }
            guard let self,self.operationID==id else{return};self.running=false;self.cancelling=false;self.task=nil
        }
    }
    func cancel() {guard running else{return};cancelling=true;task?.cancel()}
}

struct CapturePinBatchExportView:View {
    @ObservedObject var session:CapturePinSession
    @ObservedObject var model:CaptureBatchImageExportModel
    init(session:CapturePinSession) {self.session=session;self.model=session.batchExport}
    var body:some View {
        VStack(alignment:.leading,spacing:6) {
            HStack {
                Picker(tr("Image export scope"),selection:$model.allGroups) {
                    Text(tr("Selected group")).tag(false);Text(tr("All pin groups")).tag(true)
                }.frame(width:230).disabled(model.running)
                Picker(tr("Image format"),selection:$model.format) {ForEach(CaptureSaveFormat.allCases,id:\.self){Text($0.rawValue.uppercased()).tag($0)}}.frame(width:150).disabled(model.running)
                Button(tr("Export open images…")) {
                    do {
                        let items=try model.itemsForExport(from:session)
                        let format=model.format,quality=model.quality
                        guard !items.isEmpty else{throw CaptureBatchExportFailure.noImages}
                        let panel=NSOpenPanel();panel.canChooseDirectories=true;panel.canChooseFiles=false;panel.allowsMultipleSelection=false
                        guard panel.runModal() == .OK,let url=panel.url else{return}
                        model.start(items,destination:url,format:format,quality:quality)
                    } catch {model.report(error)}
                }.disabled(model.running)
                if model.running {Button(tr("Cancel")){model.cancel()}.disabled(model.cancelling)}
            }
            if model.format == .jpeg {
                HStack {Text(tr("JPEG quality"));Slider(value:$model.quality,in:0...1).frame(width:160);Text("\(Int((model.quality*100).rounded()))%").monospacedDigit()}.font(.caption).disabled(model.running)
            }
            Text(tr("Images only; includes hidden and locked pins. Closed history and other pin types are excluded.")).font(.caption).foregroundStyle(.secondary)
            if model.running {
                ProgressView(value:Double(model.completed),total:Double(max(1,model.total)))
                Text(String(format:tr("Saving images: %d / %d"),model.completed,model.total)).font(.caption)
            }
            if let issue=model.issue {Text(issue).font(.caption).foregroundStyle(.red).textSelection(.enabled)}
            if let result=model.result {
                HStack {Text(result.folder.path).font(.caption).textSelection(.enabled);Button(tr("Show exported folder")){NSWorkspace.shared.activateFileViewerSelecting([result.folder])}}
            }
        }
    }
}
