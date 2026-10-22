import AppKit
import SwiftUI
import CaptureCore
import ThermoL10n
import UniformTypeIdentifiers

struct CaptureSaveSettingsView:View {
    @ObservedObject var model:CaptureSaveModel
    @State private var draft=CaptureSaveSettings()
    @State private var error:String?
    var preview: String { (try? CaptureSaveNaming.relativePath(template:draft.quick.template,width:1920,height:1080,format:draft.quick.format)) ?? tr("Invalid filename template") }
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(tr("Capture saving and after-actions")).font(.title2.bold())
            if let message=error ?? model.issue { Text(message).foregroundStyle(.red).textSelection(.enabled) }
            ScrollView {
                VStack(alignment:.leading,spacing:14) {
                    GroupBox(tr("Quick save")) { CaptureDestinationEditor(destination:$draft.quick) }
                    Toggle(tr("Automatically save an extra copy after each successful screenshot"),isOn:$draft.autoSave)
                    GroupBox(tr("Automatic copy")) { CaptureDestinationEditor(destination:$draft.automatic) }
                    HStack { Text(tr("JPEG quality"));Slider(value:$draft.quality,in:0...1);Text("\(Int(draft.quality*100))%").monospacedDigit() }
                    Toggle(tr("Copy image after a successful manual save"),isOn:$draft.copyAfterManualSave)
                    GroupBox(tr("After selecting a screenshot")) {
                        VStack(alignment:.leading,spacing:8) {
                            Text(tr("Steps run from top to bottom. An empty chain only keeps the optional automatic copy.")).font(.caption)
                            ForEach(Array(draft.after.enumerated()),id:\.element) { index,step in
                                HStack {
                                    Text("\(index+1). "+tr(step.title));Spacer()
                                    Button(tr("Move step up")) { draft.after.swapAt(index,index-1) }.disabled(index == 0)
                                    Button(tr("Move step down")) { draft.after.swapAt(index,index+1) }.disabled(index == draft.after.count-1)
                                    Button(tr("Remove step")) { draft.after.remove(at:index) }
                                }
                            }
                            Menu(tr("Add after-action")) { ForEach(CaptureAfterStep.allCases.filter{!draft.after.contains($0)}) { step in Button(tr(step.title)) { draft.after.append(step) } } }
                        }.padding(6)
                    }
                    Text(tr("Supported filename variables: $yyyy$, $MM$, $dd$, $HH$, $mm$, $ss$, $SSS$, $yyyy-MM-dd_HH-mm-ss-SSS$, %width%, %height%, %uuid%, %os%. Use / for subfolders; the selected format sets the extension.")).font(.caption).foregroundStyle(.secondary)
                    Text(tr("Quick-save filename preview")+": "+preview).font(.caption).textSelection(.enabled)
                    Text(tr("Existing files are kept; a number is added on collision. Failed chains stop and open the captured image as a pin. Completed copies and saves are kept.")).font(.caption).foregroundStyle(.secondary)
                    if !model.saved.isEmpty { Text(tr("Last saved files")+":\n"+model.saved.map(\.path).joined(separator:"\n")).font(.caption).textSelection(.enabled) }
                }.padding(4)
            }
            HStack {
                Button(tr("Import capture saving settings…")) { importSettings() }
                Button(tr("Export saved capture saving settings…")) { exportSettings() }
                Spacer()
                Button(tr("Discard saving changes")) { draft=model.settings;error=nil }
                Button(tr("Apply saving settings")) { if model.apply(draft) {error=nil} }.disabled(model.running)
            }
        }.padding(16).frame(minWidth:760,minHeight:650).onAppear{draft=model.settings}
    }
    private func importSettings() {
        let panel=NSOpenPanel();panel.allowedContentTypes=[.json];guard panel.runModal() == .OK,let url=panel.url else{return}
        do {
            let values=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey]);guard values.isRegularFile == true,values.isSymbolicLink != true,(values.fileSize ?? Int.max)<=65536 else {throw CaptureSaveFailure.invalidSettings}
            var value=try CaptureSaveSettings.decode(Data(contentsOf:url))
            // Folder bookmarks are host-specific. Import paths as drafts and reacquire access when chosen.
            value.quick.bookmark=nil;value.automatic.bookmark=nil;draft=value;error=nil
        } catch {self.error=captureFailureMessage(error)}
    }
    private func exportSettings() {
        let panel=NSSavePanel();panel.allowedContentTypes=[.json];panel.nameFieldStringValue="Thermo-capture-saving.json";guard panel.runModal() == .OK,let url=panel.url else{return}
        do {var value=try model.snapshot();value.quick.bookmark=nil;value.automatic.bookmark=nil;try value.data().write(to:url,options:.atomic)} catch {self.error=captureFailureMessage(error)}
    }
}
private struct CaptureDestinationEditor:View {
    @Binding var destination:CaptureSaveDestination
    @State private var error:String?
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            HStack { Text(destination.directory.isEmpty ? tr("No folder selected") : destination.directory).lineLimit(2).textSelection(.enabled);Spacer();Button(tr("Choose save folder…")){choose()} }
            HStack { Text(tr("Filename template"));TextField(tr("Filename template"),text:$destination.template) }
            Picker(tr("Image format"),selection:$destination.format) {ForEach(CaptureSaveFormat.allCases,id:\.self){Text($0.rawValue.uppercased()).tag($0)}}.pickerStyle(.segmented)
            if let error {Text(error).foregroundStyle(.red)}
        }.padding(6)
    }
    private func choose() {
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true
        guard panel.runModal() == .OK,let url=panel.url else{return}
        do { let bookmark=try url.bookmarkData(options:.withSecurityScope,includingResourceValuesForKeys:nil,relativeTo:nil);destination.directory=url.path;destination.bookmark=bookmark;error=nil }
        catch {self.error=captureFailureMessage(error)}
    }
}
