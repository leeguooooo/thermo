import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n
import Quartz

struct CaptureTypedPinView:View {
    @ObservedObject var model:CaptureEditorModel
    @State private var editing=false
    @State private var selectedFiles:Set<UUID>=[]
    @State private var preview:CapturePinFile?
    @State private var colorFormat:CapturePinColor.Format = .hex
    private func run(_ action:() throws -> Void) { do { try action();model.error=nil } catch { model.error=tr(error.localizedDescription) } }
    private func update(_ text:CapturePinText) { run { try model.updatePinContent(.text(text)) } }
    var body:some View {
        VStack(spacing:10) {
            HStack {
                TextField(tr("Pin title"),text:$model.pinTitle).textFieldStyle(.roundedBorder)
                Toggle(tr("Lock pin"),isOn:$model.locked)
                Toggle(tr("Always on top"),isOn:$model.pinned).onChange(of:model.pinned) { _ in model.changeWindow?() }
                Toggle(tr("Pin shadow"),isOn:$model.shadow)
            }.padding([.top,.horizontal],10)
            if let error=model.error { HStack { Text(error).foregroundStyle(.red);if model.pinContentSaveError != nil { Button(tr("Revert unsaved edits")) { model.revertUnsavedPinText() } } }.padding(.horizontal) }
            if let content=model.pinContent {
                switch content {
                case .text(let text):textBody(text)
                case .files(let files):filesBody(files)
                case .color(let color):colorBody(color)
                case .latex(let formula):CaptureLaTeXPinView(model:model,formula:formula).id(model.pinTextReloadID)
                }
            }
            HStack {
                Slider(value:$model.opacity,in:0.2...1).frame(width:100).disabled(model.locked).help(tr("Pin opacity")).onChange(of:model.opacity) { _ in model.changeWindow?() }
                if case .text = model.pinContent { Slider(value:$model.zoom,in:0.25...4).frame(width:85).disabled(model.locked).help(tr("Zoom")) }
                Button(tr("Create image copy")) {
                    Task { do {
                        let image:CGImage
                        if case .text = model.pinContent,let snapshot=model.snapshotPinContent { image=try await snapshot() }
                        else if let content=model.pinContent { image=try content.previewImage() }
                        else { throw CaptureFailure.invalidImage }
                        model.makeImageCopy?(image)
                    } catch { model.error=tr(error.localizedDescription) } }
                }.help(tr("Text image copies contain only the visible area.")).disabled(model.pinContentSaveError != nil)
                Spacer()
                if let show=model.showPinLibrary { Button(tr("Pin groups and history"),action:show) }
            }.padding([.horizontal,.bottom],10)
        }.sheet(item:$preview) { file in
            VStack {
                HStack { Text(URL(fileURLWithPath:file.path).lastPathComponent).font(.headline);Spacer();Button(tr("Close")) { preview=nil } }.padding()
                CaptureFilePreview(file:file)
            }.frame(width:720,height:520)
        }
    }
    @ViewBuilder private func textBody(_ text:CapturePinText) -> some View {
        VStack(spacing:8) {
            ScrollView(.horizontal,showsIndicators:false) {
                HStack {
                    Toggle(tr("Ignore formatting"),isOn:Binding(get:{ text.ignoreFormatting },set:{ var value=text;value.ignoreFormatting=$0;update(value) }))
                    if text.usesHTML {
                        Button(tr("Edit as plain text")) { var value=text;value.html=nil;value.rtf=nil;value.ignoreFormatting=true;update(value);editing=true }.disabled(text.plain.isEmpty)
                    } else { Toggle(tr("Edit text"),isOn:$editing) }
                    Button(tr("Copy text")) { NSPasteboard.general.clearContents();NSPasteboard.general.setString(text.plain,forType:.string) }.disabled(text.plain.isEmpty)
                    Button(tr("Copy with formatting")) { run { try CapturePinClipboard.copy(.text(text),to:.general) } }.disabled(text.rtf == nil && text.html == nil)
                }.padding(.horizontal,10)
            }
            if text.ignoreFormatting || (text.rtf == nil && text.html == nil) {
                HStack {
                    TextField(tr("Text font"),text:Binding(get:{ text.fontName },set:{ var value=text;value.fontName=$0;update(value) })).frame(width:110).textFieldStyle(.roundedBorder)
                    Stepper(tr("Font size")+" \(Int(text.fontSize))",value:Binding(get:{ text.fontSize },set:{ var value=text;value.fontSize=$0;update(value) }),in:8...96).fixedSize()
                    ColorPicker(tr("Text color"),selection:Binding(get:{ Color(nsColor:CapturePinText.color(text.foreground)) },set:{ var value=text;value.foreground=rgba($0);update(value) }))
                    ColorPicker(tr("Text background"),selection:Binding(get:{ Color(nsColor:CapturePinText.color(text.background)) },set:{ var value=text;value.background=rgba($0);update(value) }))
                }.padding(.horizontal,10)
            }
            if text.usesHTML {
                CaptureHTMLPinView(text:text,model:model)
                Text(tr("HTML preview is offline. Links and scripts are disabled.")).font(.caption).foregroundStyle(.secondary)
            } else { CaptureNativeTextPin(text:text,editable:editing && !model.locked,model:model,onChange:update).id(model.pinTextReloadID) }
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func filesBody(_ files:[CapturePinFile]) -> some View {
        VStack {
            CaptureFileList(files:files,selection:$selectedFiles,onOpen:{ file in openFile(file) })
            HStack {
                Button(tr("Open file")) { if let file=chosen(files).first { openFile(file) } }.disabled(chosen(files).count != 1)
                Button(tr("Preview file")) { if let file=chosen(files).first { preview=file } }.disabled(chosen(files).count != 1)
                Button(tr("Show in Finder")) { run { NSWorkspace.shared.activateFileViewerSelecting(try chosen(files).map { try $0.resolved() }) } }
                Button(tr("Copy files")) { run { try CapturePinClipboard.copy(.files(files),to:.general,selectedFiles:selectedFiles.isEmpty ? nil : selectedFiles) } }
                Button(tr("Copy file paths")) { run { let text=try chosen(files).map { try $0.resolved().path }.joined(separator:"\n");NSPasteboard.general.clearContents();NSPasteboard.general.setString(text,forType:.string) } }
            }.padding(.horizontal,10)
            Text(tr("Select files to act on them; an empty selection uses all files.")).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func chosen(_ files:[CapturePinFile]) -> [CapturePinFile] { files.filter { selectedFiles.isEmpty || selectedFiles.contains($0.id) } }
    private func openFile(_ file:CapturePinFile) {
        run {
            let url=try file.resolved();guard FileManager.default.fileExists(atPath:url.path) else { throw CapturePinFailure.missingSourceFile }
            guard NSWorkspace.shared.open(url) else { throw CaptureFailure.exportFailed }
        }
    }
    private func colorBody(_ color:CapturePinColor) -> some View {
        VStack(spacing:18) {
            ColorPicker(tr("Pin color"),selection:Binding(get:{ Color(nsColor:color.nsColor) },set:{ value in
                let c=NSColor(value).usingColorSpace(.sRGB) ?? .black
                run { try model.updatePinContent(.color(.init(red:Int((c.redComponent*255).rounded()),green:Int((c.greenComponent*255).rounded()),blue:Int((c.blueComponent*255).rounded()),alpha:c.alphaComponent))) }
            }),supportsOpacity:true).padding()
            RoundedRectangle(cornerRadius:12).fill(Color(nsColor:color.nsColor)).overlay(RoundedRectangle(cornerRadius:12).stroke(.gray)).frame(maxWidth:420,maxHeight:200)
            Picker(tr("Color format"),selection:$colorFormat) { ForEach(CapturePinColor.Format.allCases,id:\.self) { Text($0.rawValue).tag($0) } }.frame(width:220)
            Text(color.formatted(colorFormat)).font(.system(size:24,design:.monospaced)).textSelection(.enabled).onDrag { NSItemProvider(object:color.formatted(colorFormat) as NSString) }
            Button(tr("Copy color value")) { run { try CapturePinClipboard.copy(.color(color),to:.general,format:colorFormat) } }
        }.padding().frame(maxWidth:.infinity,maxHeight:.infinity)
    }
    private func rgba(_ value:Color) -> [Double] {
        let c=NSColor(value).usingColorSpace(.deviceRGB) ?? .black;return [c.redComponent,c.greenComponent,c.blueComponent,c.alphaComponent]
    }
}

private struct CaptureFilePreview:NSViewRepresentable {
    let file:CapturePinFile
    func makeNSView(context:Context) -> QLPreviewView { QLPreviewView(frame:.zero,style:.normal)! }
    func updateNSView(_ view:QLPreviewView,context:Context) { view.previewItem=(try? file.resolved()) as NSURL? }
}
