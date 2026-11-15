import ThermoUI
import AppKit
import SearchCore
import SwiftUI
import ThermoL10n

/// The kernel owns the file actions; all document parsing and preview UI live in the sandbox renderer.
struct SearchFilePreviewView:View {
    let item:SearchItem
    let open:()->Void
    let reveal:()->Void
    @State private var request=UUID()
    @ObservedObject private var preview=SearchPreviewController.shared
    @ObservedObject private var center=ModuleCenter.shared
    var body:some View {
        VStack(spacing:0) {
            HStack(spacing:12) {
                Image(nsImage:NSWorkspace.shared.icon(forFile:item.path)).resizable().frame(width:28,height:28)
                VStack(alignment:.leading,spacing:3) {
                    Text(item.name).font(Theme.rowTitle).lineLimit(1).truncationMode(.middle)
                    Text((item.path as NSString).deletingLastPathComponent).font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength:12)
                Button(action:reveal){Image(systemName:"folder")}.help(tr("Show in Finder")).accessibilityLabel(tr("Show in Finder"))
                Button(tr("Open"),action:open)
            }.padding(.horizontal,20).padding(.vertical,12)
            Rectangle().fill(Theme.hairline).frame(height:1)
            Group {
                switch preview.state {
                case let .ready(id) where id == request:
                    ModuleSceneView(manager:center.manager,module:preview.worker,scene:"preview").id(request)
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
        }.background(Theme.canvas).preferredColorScheme(.dark)
        .task(id:request){guard !Task.isCancelled else{return};preview.open(item,roots:LocalSearchModel.shared.preferences.roots,request:request)}
        .onDisappear{preview.stop(ifCurrent:request)}
        .onChange(of:center.statuses){_ in preview.observeStatus()}
    }
}
