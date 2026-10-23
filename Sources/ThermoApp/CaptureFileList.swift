import AppKit
import CaptureCore
import SwiftUI

struct CaptureFileList:NSViewRepresentable {
    let files:[CapturePinFile]
    @Binding var selection:Set<UUID>
    let onOpen:(CapturePinFile)->Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true
        let table=NSTableView(frame:CGRect(x:0,y:0,width:640,height:200));table.autoresizingMask=[.width];let column=NSTableColumn(identifier:.init("files"));column.title="";column.width=640;column.resizingMask = .autoresizingMask;table.addTableColumn(column)
        table.headerView=nil;table.rowHeight=48;table.allowsMultipleSelection=true;table.dataSource=context.coordinator;table.delegate=context.coordinator;table.target=context.coordinator;table.doubleAction=#selector(Coordinator.open)
        table.setDraggingSourceOperationMask(.copy,forLocal:false);scroll.documentView=table;return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let table=scroll.documentView as? NSTableView else { return }
        let changed=context.coordinator.parent.files != files;context.coordinator.parent=self
        if changed || table.numberOfRows != files.count { table.reloadData() }
        let indices=IndexSet(files.indices.filter { selection.contains(files[$0].id) })
        if table.selectedRowIndexes != indices { table.selectRowIndexes(indices,byExtendingSelection:false) }
    }
    final class Coordinator:NSObject,NSTableViewDataSource,NSTableViewDelegate {
        var parent:CaptureFileList
        init(_ parent:CaptureFileList) { self.parent=parent }
        func numberOfRows(in tableView:NSTableView) -> Int { parent.files.count }
        func tableView(_ tableView:NSTableView,viewFor tableColumn:NSTableColumn?,row:Int) -> NSView? {
            let file=parent.files[row],url=(try? file.resolved()) ?? URL(fileURLWithPath:file.path)
            let cell=NSTableCellView(frame:CGRect(x:0,y:0,width:600,height:48))
            let icon=NSImageView(frame:CGRect(x:6,y:8,width:32,height:32));icon.image=NSWorkspace.shared.icon(forFile:url.path);cell.addSubview(icon)
            let label=NSTextField(labelWithString:url.lastPathComponent+"\n"+url.path);label.frame=CGRect(x:48,y:5,width:max(100,tableView.bounds.width-60),height:40);label.autoresizingMask=[.width];label.lineBreakMode = .byTruncatingMiddle;label.maximumNumberOfLines=2;cell.addSubview(label)
            cell.textField=label;cell.imageView=icon;cell.setAccessibilityLabel(url.path);return cell
        }
        func tableViewSelectionDidChange(_ notification:Notification) {
            guard let table=notification.object as? NSTableView else { return }
            parent.selection=Set(table.selectedRowIndexes.compactMap { parent.files.indices.contains($0) ? parent.files[$0].id : nil })
        }
        func tableView(_ tableView:NSTableView,pasteboardWriterForRow row:Int) -> NSPasteboardWriting? { (try? parent.files[row].resolved()) as NSURL? }
        @objc func open(_ sender:NSTableView) { if parent.files.indices.contains(sender.clickedRow) { parent.onOpen(parent.files[sender.clickedRow]) } }
    }
}
