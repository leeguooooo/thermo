import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n

@MainActor final class CaptureNormalOverlayWindow:NSWindowController {
    private let model:CaptureNormalOverlayModel
    init(image:CGImage,annotations:[CaptureVectorAnnotation],duration:Double,apply:@escaping([CaptureVectorAnnotation])->Void) {
        model=CaptureNormalOverlayModel(image:image,annotations:annotations,duration:duration,apply:apply)
        let window=NSWindow(contentRect:NSRect(x:0,y:0,width:880,height:680),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        window.title=tr("Recording annotations");window.isReleasedWhenClosed=false;window.level = .floating;window.center()
        super.init(window:window)
        model.close={ [weak self] in self?.close() }
        window.contentView=NSHostingView(rootView:CaptureNormalOverlayView(model:model))
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
}

@MainActor private final class CaptureNormalOverlayModel:ObservableObject {
    let canvas:CaptureEditorModel
    @Published var start:Double
    @Published var end:Double
    let duration:Double
    let apply:([CaptureVectorAnnotation])->Void
    var close:(()->Void)?
    init(image:CGImage,annotations:[CaptureVectorAnnotation],duration:Double,apply:@escaping([CaptureVectorAnnotation])->Void) {
        canvas=CaptureEditorModel(image:image);self.duration=duration;self.apply=apply
        start=annotations.first?.start ?? 0;end=annotations.first?.end ?? duration
        for item in annotations { if let annotation=item.annotation { canvas.document.append(annotation) } }
    }
    func commit() {
        guard start >= 0,end > start,end <= duration else { return }
        apply(canvas.document.annotations.map { CaptureVectorAnnotation($0,start:start,end:end) });close?()
    }
}
private struct CaptureNormalOverlayView:View {
    @ObservedObject var model:CaptureNormalOverlayModel
    var body:some View {
        VStack(spacing:10) {
            NormalOverlayTools(model:model.canvas)
            CaptureCanvas(model:model.canvas).frame(maxWidth:.infinity,maxHeight:.infinity)
            HStack {
                Text(tr("Visible from (s)"));TextField("",value:$model.start,format:.number).frame(width:70)
                Text(tr("Visible until (s)"));TextField("",value:$model.end,format:.number).frame(width:70)
                Spacer()
                Button(tr("Apply annotations")) { model.commit() }.disabled(model.start < 0 || model.end <= model.start || model.end > model.duration)
            }.textFieldStyle(.roundedBorder)
        }.padding(12)
    }
}
private struct NormalOverlayTools:View {
    @ObservedObject var model:CaptureEditorModel
    var body:some View {
        HStack {
            ForEach(CaptureTool.allCases.filter { $0 != .crop }) { tool in
                Button { model.tool=tool } label: { Image(systemName:tool.symbol).frame(width:20,height:24) }
                    .help(tr(tool.label)).accessibilityLabel(tr(tool.label)).background(model.tool == tool ? Color.accentColor.opacity(0.25) : Color.clear).cornerRadius(4)
            }
            ColorPicker(tr("Annotation color"),selection:$model.color).labelsHidden()
            Slider(value:$model.lineWidth,in:1...12).frame(width:60).help(tr("Line width"))
            Button { model.document.undo() } label: { Image(systemName:"arrow.uturn.backward") }.disabled(!model.document.canUndo).help(tr("Undo"))
            Button { model.document.redo() } label: { Image(systemName:"arrow.uturn.forward") }.disabled(!model.document.canRedo).help(tr("Redo"))
        }
        if model.tool == .text { TextField(tr("Annotation text"),text:$model.text).textFieldStyle(.roundedBorder) }
    }
}

struct CaptureNormalSettings:View {
    @ObservedObject var model:CaptureRecordingModel
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            CaptureAVLayerSettings(model:model)
            CaptureKeyboardSettings(model:model)
            HStack {
                Toggle(tr("Show cursor"),isOn:$model.normalEdits.showCursor)
                Toggle(tr("Show mouse actions"),isOn:$model.normalEdits.showClicks)
                Slider(value:$model.normalEdits.cursorScale,in:0.25...4).frame(width:80).help(tr("Cursor size"))
                Picker(tr("Progress display"),selection:$model.normalEdits.progress) {
                    Text(tr("No progress overlay")).tag(CaptureNormalEdits.Progress.none)
                    Text(tr("Elapsed time")).tag(CaptureNormalEdits.Progress.elapsed)
                    Text(tr("Countdown")).tag(CaptureNormalEdits.Progress.remaining)
                }
            }
            HStack {
                TextField(tr("Watermark"),text:$model.normalEdits.watermark).textFieldStyle(.roundedBorder)
                Text(tr("System volume"))
                Slider(value:$model.normalEdits.systemVolume,in:0...1).frame(width:90).disabled(model.normalSource?.audioURL == nil)
            }
            HStack {
                cropField(tr("Left (%)"),get:{ Double(model.normalEdits.crop.minX)*100 },set:{ model.normalEdits.crop.origin.x=$0/100 })
                cropField(tr("Top (%)"),get:{ (1-Double(model.normalEdits.crop.maxY))*100 },set:{ model.normalEdits.crop.origin.y=1-$0/100-model.normalEdits.crop.height })
                cropField(tr("Width (%)"),get:{ Double(model.normalEdits.crop.width)*100 },set:{ model.normalEdits.crop.size.width=$0/100 })
                cropField(tr("Height (%)"),get:{ Double(model.normalEdits.crop.height)*100 },set:{ value in
                    let top=1-model.normalEdits.crop.maxY
                    model.normalEdits.crop.size.height=value/100;model.normalEdits.crop.origin.y=1-top-value/100
                })
                Button(tr("Reset crop")) { model.normalEdits.crop=CGRect(x:0,y:0,width:1,height:1) }
            }
            HStack {
                Button(tr("Edit annotations…")) { model.editNormalAnnotations() }
                Button(tr("Apply edits / refresh preview")) { model.applyNormalEdits() }.disabled(!model.normalEdits.valid)
                Text(tr("Original frames stay editable.")).font(.caption).foregroundStyle(.secondary)
            }
        }.disabled(model.active || model.exporting)
    }
    private func cropField(_ label:String,get:@escaping()->Double,set:@escaping(Double)->Void) -> some View {
        HStack(spacing:3) { Text(label).font(.caption);TextField("",value:Binding(get:get,set:set),format:.number).frame(width:42).textFieldStyle(.roundedBorder) }
    }
}

struct CaptureAVLayerSettings:View {
    @ObservedObject var model:CaptureRecordingModel
    private func camera<T>(_ path:WritableKeyPath<CaptureCameraEdits,T>) -> Binding<T> {
        Binding(get:{ (model.normalEdits.camera ?? CaptureCameraEdits())[keyPath:path] },set:{ value in
            var settings=model.normalEdits.camera ?? CaptureCameraEdits();settings[keyPath:path]=value;model.normalEdits.camera=settings
        })
    }
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            if let source=model.normalSource,FileManager.default.fileExists(atPath:source.root.appendingPathComponent("camera").path) {
                HStack {
                    Toggle(tr("Show camera layer"),isOn:camera(\.enabled))
                    Toggle(tr("Mirror camera"),isOn:camera(\.mirrored))
                    Slider(value:camera(\.width),in:0.05...0.5).frame(width:90).help(tr("Camera layer size"))
                }
                HStack {
                    Picker(tr("Camera position"),selection:camera(\.corner)) {
                        Text(tr("Top left")).tag(CaptureCameraEdits.Corner.topLeft);Text(tr("Top right")).tag(CaptureCameraEdits.Corner.topRight)
                        Text(tr("Bottom left")).tag(CaptureCameraEdits.Corner.bottomLeft);Text(tr("Bottom right")).tag(CaptureCameraEdits.Corner.bottomRight)
                    }
                    Picker(tr("Camera shape"),selection:camera(\.shape)) {
                        Text(tr("Rounded rectangle")).tag(CaptureCameraEdits.Shape.rectangle);Text(tr("Circle")).tag(CaptureCameraEdits.Shape.circle)
                    }
                }
            }
            if model.normalSource?.microphoneURL != nil {
                HStack {
                    Text(tr("Microphone volume"))
                    Slider(value:Binding(get:{ model.normalEdits.microphoneVolume ?? 1 },set:{ model.normalEdits.microphoneVolume=$0 }),in:0...1)
                }
            }
        }
    }
}

struct CaptureKeyboardSettings:View {
    @ObservedObject var model:CaptureRecordingModel
    private func setting<T>(_ key:WritableKeyPath<CaptureKeyboardEdits,T>) -> Binding<T> {
        Binding(get:{ (model.normalEdits.keyboard ?? CaptureKeyboardEdits())[keyPath:key] },set:{ value in
            var settings=model.normalEdits.keyboard ?? CaptureKeyboardEdits();settings[keyPath:key]=value;model.normalEdits.keyboard=settings
        })
    }
    var body:some View {
        if let source=model.normalSource,!source.keys.isEmpty {
            HStack {
                Picker(tr("Keyboard overlay"),selection:setting(\.mode)) {
                    Text(tr("Hidden")).tag(CaptureKeyMode.hidden);Text(tr("Shortcuts only")).tag(CaptureKeyMode.shortcuts)
                    Text(tr("All recorded keys")).tag(CaptureKeyMode.all)
                }
                Slider(value:setting(\.hold),in:0.2...5).frame(width:80).help(tr("Key display duration"))
                Slider(value:setting(\.scale),in:0.5...3).frame(width:70).help(tr("Key display size"))
                Toggle(tr("Keys at top"),isOn:setting(\.top))
            }
        }
    }
}
