import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers

struct CaptureActionSettingsView:View {
    @ObservedObject var model:CaptureShortcutModel
    @State private var draft=CaptureActionSettings()
    @State private var selected:UUID?
    @State private var error:String?
    private var index:Int? { draft.entries.firstIndex { $0.id == selected } }
    var body:some View {
        VStack(spacing:12) {
            HStack {
                Toggle(tr("Enable capture shortcuts"),isOn:$draft.shortcutsEnabled)
                Spacer();Button(tr("Restore default shortcuts")) { draft = .defaults;selected=draft.entries.first?.id }
                Button(tr("Import shortcut settings…")) { importSettings() }
                Button(tr("Export saved shortcut settings…")) { exportSettings() }
            }
            if let issue=error ?? model.issue { Text(issue).foregroundStyle(.red).frame(maxWidth:.infinity,alignment:.leading) }
            HStack(alignment:.top,spacing:18) {
                VStack {
                    List(selection:$selected) {
                        ForEach(draft.entries) { entry in
                            VStack(alignment:.leading,spacing:4) {
                                Text(entry.title.isEmpty ? tr(entry.action.title) : entry.title)
                                HStack { Text(entry.shortcut?.label ?? tr("No shortcut"));Text(tr(entry.scope == .global ? "Global" : "Pin window only"));Spacer();Text(model.settings.entries.contains(entry) ? model.state(for:entry) : tr("Not applied")) }.font(.caption).foregroundStyle(.secondary)
                            }.tag(entry.id)
                        }
                    }
                    HStack {
                        Button(tr("Add action")) { let entry=CaptureShortcutEntry(action:.screenshot);draft.entries.append(entry);selected=entry.id }
                        Button(tr("Remove action")) { if let selected { draft.entries.removeAll { $0.id == selected };self.selected=draft.entries.first?.id } }.disabled(index == nil)
                    }
                }.frame(minWidth:330)
                if let index {
                    CaptureActionEntryEditor(model:model,entry:$draft.entries[index]).id(draft.entries[index].id).frame(width:380)
                } else { Text(tr("Select an action to configure.")).foregroundStyle(.secondary).frame(width:380) }
            }
            HStack {
                Text(tr("Pin shortcuts override the same global gesture while a pin is focused. Plain typing in text fields is preserved.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                Spacer();Button(tr("Discard shortcut changes")) { draft=model.settings;selected=draft.entries.first?.id;error=nil }
                Button(tr("Apply shortcut settings")) { if model.apply(draft) { draft=model.settings;error=nil } }.disabled(model.uncertain)
            }
        }.padding(16).onAppear { draft=model.settings;selected=draft.entries.first?.id }
    }
    private func importSettings() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];guard panel.runModal() == .OK,let url=panel.url else { return }
        do { let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]);guard values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? Int.max) <= 65536 else { throw CaptureActionFailure.invalidSettings };draft=try .decode(Data(contentsOf:url));selected=draft.entries.first?.id;error=nil }
        catch { self.error=captureFailureMessage(error) }
    }
    private func exportSettings() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Thermo-capture-shortcuts.json";guard panel.runModal() == .OK,let url=panel.url else { return }
        do { try model.settings.data().write(to:url,options:.atomic) } catch { self.error=captureFailureMessage(error) }
    }
}
private struct CaptureActionEntryEditor:View {
    @ObservedObject var model:CaptureShortcutModel
    @Binding var entry:CaptureShortcutEntry
    var body:some View {
        VStack(alignment:.leading,spacing:14) {
            TextField(tr("Action name (optional)"),text:$entry.title).textFieldStyle(.roundedBorder)
            Picker(tr("Action"),selection:$entry.action) { ForEach(CaptureAction.allCases) { Text(tr($0.title)).tag($0) } }
            Picker(tr("Shortcut scope"),selection:$entry.scope) { Text(tr("Global")).tag(CaptureShortcutEntry.Scope.global);Text(tr("Pin window only")).tag(CaptureShortcutEntry.Scope.pin) }
            Toggle(tr("Action enabled"),isOn:$entry.enabled)
            Toggle(tr("Show in capture actions menu"),isOn:Binding(get:{ entry.showInMenu ?? true },set:{ entry.showInMenu=$0 }))
            CaptureShortcutRecorder(model:model,value:$entry.shortcut).frame(height:32)
            HStack {
                Button(tr("Remove shortcut")) { entry.shortcut=nil }
                if entry.scope == .pin { Menu(tr("Key presets")) { Button("Esc") { entry.shortcut = .init(keyCode:53,modifiers:0,keyLabel:"Esc") };Button(tr("Space")) { entry.shortcut = .init(keyCode:49,modifiers:0,keyLabel:"Space") };Button(tr("Delete")) { entry.shortcut = .init(keyCode:51,modifiers:0,keyLabel:"⌫") } } }
            }
            Text(tr("Global shortcuts need Command, Control, Option or a function key. Pin-window shortcuts can use ordinary keys.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Button(tr("Run selected action")) { model.run(entry.action) }
            CaptureConfiguredActionsMenu(model:model,onIssue:{})
            Text(tr("Changes take effect only after Apply.")).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Spacer()
        }
    }
}
private struct CaptureShortcutRecorder:NSViewRepresentable {
    let model:CaptureShortcutModel
    @Binding var value:CaptureShortcut?
    func makeNSView(context:Context) -> Button { let button=Button();button.model=model;return button }
    func updateNSView(_ button:Button,context:Context) { button.model=model;button.receive={ value=$0 };button.title=model.recordingOwner == button.owner ? tr("Press a shortcut; Esc cancels") : value?.label ?? tr("Record shortcut…");button.isEnabled = !model.uncertain;button.setAccessibilityLabel(tr("Record capture shortcut")) }
    final class Button:NSButton {
        let owner=UUID()
        weak var model:CaptureShortcutModel?
        var receive:((CaptureShortcut)->Void)?
        override var acceptsFirstResponder:Bool { true }
        init() { super.init(frame:.zero);bezelStyle = .rounded;target=self;action=#selector(begin) }
        required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
        @objc private func begin() { model?.beginRecording(owner) { [weak self] key in self?.receive?(key) };window?.makeFirstResponder(self) }
        override func resignFirstResponder() -> Bool { model?.cancelRecording(owner);return super.resignFirstResponder() }
        override func performKeyEquivalent(with event:NSEvent) -> Bool { if model?.recordingOwner == owner,event.type == .keyDown { keyDown(with:event);return true };return super.performKeyEquivalent(with:event) }
        override func keyDown(with event:NSEvent) {
            guard let model,model.recordingOwner == owner else { super.keyDown(with:event);return }
            if event.keyCode == 53 { model.cancelRecording(owner);return }
            let key=CleanScreenKeyBinding.captured(event);model.record(.init(keyCode:key.keyCode,modifiers:key.modifiers,keyLabel:key.keyLabel),owner:owner)
        }
    }
}
