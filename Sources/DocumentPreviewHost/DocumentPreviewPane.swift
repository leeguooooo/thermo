import AppKit
import DocumentPreviewAPI
import ModuleHost
import SwiftUI
import ThermoL10n
import ThermoUI

struct DocumentPreviewPane:View {
    @ObservedObject var preview:DocumentPreviewController
    let selection:SelectedDocument
    let roots:[String]
    @State var request:UUID
    var body:some View {
        Group {
            switch preview.state {
            case let .ready(id) where id == request:
                DocumentPreviewScene(manager:preview.broker.manager,module:preview.worker,allowed:{[weak preview] in preview?.canAttach(request) == true}).id(request)
            case let .failed(issue):
                VStack(spacing:16) {
                    Image(systemName:"exclamationmark.triangle").font(.system(size:32)).foregroundStyle(Theme.caution)
                    Text(tr("Unable to preview this document")).font(Theme.body)
                    Text(issue).font(Theme.secondary).foregroundStyle(Theme.textSecondary).textSelection(.enabled)
                    Button(tr("Retry")){request=UUID()}.buttonStyle(PillButtonStyle())
                }.padding(30)
            default:ProgressView(tr("Preparing preview…"))
            }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
        .task(id:request){guard !Task.isCancelled else{return};preview.open(selection,roots:roots,request:request)}
        .onDisappear{preview.stop(ifCurrent:request)}
        .onReceive(preview.broker.statuses){_ in preview.observeStatus()}
    }
}
private struct DocumentPreviewScene:NSViewControllerRepresentable {
    let manager:ModuleManager
    let module:String
    let allowed:@MainActor ()->Bool
    final class Coordinator {
        let manager:ModuleManager
        var scene:ModuleManager.Scene?
        init(manager:ModuleManager){self.manager=manager}
    }
    func makeCoordinator()->Coordinator {Coordinator(manager:manager)}
    func makeNSViewController(context:Context)->NSViewController {
        guard allowed(),let scene=try? manager.attach(module,scene:"preview") else{return NSViewController()}
        context.coordinator.scene=scene;return scene.controller
    }
    func updateNSViewController(_ view:NSViewController,context:Context){}
    static func dismantleNSViewController(_ view:NSViewController,coordinator:Coordinator) {
        MainActor.assumeIsolated {if let scene=coordinator.scene{coordinator.manager.detach(scene);coordinator.scene=nil}}
    }
}
