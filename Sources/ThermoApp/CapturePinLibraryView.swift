import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n

struct CapturePinLibraryView:View {
    @ObservedObject var session:CapturePinSession
    @State private var name=""
    @State private var color=""
    @State private var selected:UUID?
    @State private var switchNew=true
    private enum Deletion {
        case group(UUID),contents(UUID),pin(UUID)
        var title:String { switch self { case .group:return "Delete group and its pins";case .contents:return "Clear pin group";case .pin:return "Destroy pin" } }
    }
    @State private var deletion:Deletion?
    @State private var reload=false
    private var groupID:UUID { selected ?? session.library.currentGroupID }
    private var group:CapturePinGroup? { session.library.groups.first { $0.id == groupID } }
    private func run(_ action:() throws -> Void) { do { try action();session.issue=nil } catch { session.issue=tr(error.localizedDescription) } }
    var body:some View {
        VStack(spacing:12) {
            if let issue=session.issue { HStack { Text(issue).foregroundStyle(.red);Button(tr("Retry loading pins")) { reload=true }
                    .alert(tr("Reopen saved pin session?"),isPresented:$reload) {
                        Button(tr("Cancel"),role:.cancel) {}
                        Button(tr("Reopen")) { session.retryLoad() }
                    } message:{ Text(tr("Unsaved changes in open pins will be discarded.")) } } }
            HStack(alignment:.top,spacing:14) {
                VStack(alignment:.leading,spacing:8) {
                    HStack { Text(tr("Pin groups")).font(.headline);Spacer();Text(tr("Open / total")).font(.caption).foregroundStyle(.secondary) }
                    List(session.library.groups,selection:Binding(get:{ Optional(groupID) },set:{ selected=$0;loadFields() })) { item in
                        HStack {
                            Circle().fill(groupColor(item.color)).frame(width:9,height:9)
                            Text(item.name);Spacer()
                            let all=session.library.pins.filter { $0.groupID == item.id }
                            Text("\(all.filter { $0.closedAt == nil }.count)/\(all.count)").foregroundStyle(.secondary)
                            if item.id == session.library.currentGroupID { Image(systemName:"checkmark") }
                        }.tag(item.id)
                    }.frame(minWidth:210,maxWidth:260)
                    HStack {
                        Button(tr("Switch group")) { run { try session.switchGroup(groupID) } }
                        Button { run { try session.reorderGroup(groupID,offset:-1) } } label:{ Image(systemName:"arrow.up") }.help(tr("Move group up"))
                        Button { run { try session.reorderGroup(groupID,offset:1) } } label:{ Image(systemName:"arrow.down") }.help(tr("Move group down"))
                    }
                    TextField(tr("Pin group name"),text:$name)
                    TextField(tr("Color label (#RRGGBB, optional)"),text:$color)
                    Toggle(tr("Switch to new group"),isOn:$switchNew)
                    HStack {
                        Button(tr("Create group")) { run { let id=try session.createGroup(name:name,color:color.isEmpty ? nil : color,switchTo:switchNew);selected=id;loadFields() } }
                        Button(tr("Apply group changes")) { run { try session.updateGroup(groupID,name:name,color:color.isEmpty ? nil : color) } }
                    }
                    Menu(tr("Delete group")) {
                        ForEach(session.library.groups.filter { $0.id != groupID }) { destination in
                            Button(tr("Move pins to")+" "+destination.name) { run { try session.removeGroup(groupID,movingTo:destination.id);selected=nil;loadFields() } }
                        }
                        Button(tr("Delete group and its pins"),role:.destructive) { deletion = .group(groupID) }
                    }.disabled(session.library.groups.count <= 1)
                    Button(tr("Clear pin group"),role:.destructive) { deletion = .contents(groupID) }
                }
                Divider()
                VStack(alignment:.leading,spacing:8) {
                    Text(group?.name ?? "").font(.headline)
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:12) {
                            ForEach(session.library.pins.filter { $0.groupID == groupID }) { pin in
                                HStack(alignment:.top) {
                                    VStack(alignment:.leading) {
                                        Text(pin.title.isEmpty ? String(pin.id.uuidString.prefix(8)) : pin.title).lineLimit(2)
                                        Text(tr(pin.closedAt == nil ? "Open pin" : "Closed pin")).foregroundStyle(.secondary).font(.caption)
                                    }
                                    Spacer()
                                    if pin.closedAt != nil {
                                        Button(tr("Restore pin")) { run { if groupID != session.library.currentGroupID { try session.switchGroup(groupID) };try session.restore(pin.id) } }
                                    }
                                    Menu(tr("Move to group")) {
                                        ForEach(session.library.groups.filter { $0.id != pin.groupID }) { target in
                                            Button(target.name) { run { try session.movePin(pin.id,to:target.id) } }
                                        }
                                        Divider()
                                        Button(tr("Destroy pin"),role:.destructive) { deletion = .pin(pin.id) }
                                    }.fixedSize()
                                }
                                Divider()
                            }
                            if !session.library.pins.contains(where:{ $0.groupID == groupID }) { Text(tr("No pins in this group.")).foregroundStyle(.secondary) }
                        }
                    }
                    HStack {
                        Text(tr("History per group"))
                        Picker(tr("History per group"),selection:Binding(get:{ session.library.historyLimit },set:{ value in run { try session.setHistoryLimit(value) } })) {
                            ForEach(Array(Set([0,10,25,50,100,session.library.historyLimit])).sorted(),id:\.self) { Text(String($0)).tag($0) }
                        }.labelsHidden().frame(width:85)
                        Spacer()
                    }
                    HStack {
                        Button(tr("Restore last closed pin")) { run { try session.restore() } }
                        Button(tr("Bring pins on screen")) { session.ensureAllVisible() }
                    }
                }.frame(maxWidth:.infinity)
            }
            Text(tr("Active pin group")+": "+(session.library.groups.first { $0.id == session.library.currentGroupID }?.name ?? "")).font(.caption).foregroundStyle(.secondary).frame(maxWidth:.infinity,alignment:.leading)
            HStack {
                Button(tr("Show all pins")) { run { try session.setAllHidden(false) } }
                Button(tr("Hide all pins")) { run { try session.setAllHidden(true) } }
                Button(tr("Close all pins")) { session.closeAll() }
                Spacer()
                Button(tr("Save pin session")) { run { try session.flush() } }
            }
        }.textFieldStyle(.roundedBorder).padding(16).onAppear { loadFields() }
            .alert(tr(deletion?.title ?? "Delete"),isPresented:Binding(get:{ deletion != nil },set:{ if !$0 { deletion=nil } })) {
                Button(tr("Cancel"),role:.cancel) { deletion=nil }
                Button(tr("Delete"),role:.destructive) {
                    if let deletion { run {
                        switch deletion {
                        case .group(let id):try session.removeGroup(id,movingTo:nil);selected=nil;loadFields()
                        case .contents(let id):try session.clearGroup(id)
                        case .pin(let id):try session.destroyPin(id)
                        }
                    } };deletion=nil
                }
            } message:{ Text(tr("Deleted pins cannot be restored from history.")) }
    }
    private func loadFields() { name=group?.name ?? "";color=group?.color ?? "" }
    private func groupColor(_ value:String?) -> Color {
        guard let value,let hex=UInt32(value.dropFirst(),radix:16) else { return .accentColor }
        return Color(red:Double((hex >> 16)&255)/255,green:Double((hex >> 8)&255)/255,blue:Double(hex&255)/255)
    }
}
