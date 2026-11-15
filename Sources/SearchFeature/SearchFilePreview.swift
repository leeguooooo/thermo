import DocumentPreviewAPI
import ThermoUI
import AppKit
import SearchCore
import SwiftUI
import ThermoL10n

/// The kernel owns the file actions; all document parsing and preview UI live in the sandbox renderer.
struct SearchFilePreviewView:View {
    let item:SearchItem
    let roots:[String]
    let preview:any DocumentPreviewPresentation
    let open:()->Void
    let reveal:()->Void
    @State private var request=UUID()
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
            preview.content(selection:.init(path:item.path,name:item.name,kind:item.kind == .folder ? .directory:.file),roots:roots,request:request)
        }.background(Theme.canvas).preferredColorScheme(.dark)
    }
}
