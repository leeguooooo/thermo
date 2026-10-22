import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n

struct CaptureAnnotationControls:View {
    @ObservedObject var model:CaptureEditorModel
    private var tool:CaptureTool {
        if let index=model.selectedAnnotation,model.document.annotations.indices.contains(index) { return model.document.annotations[index].tool }
        return model.tool
    }
    var body:some View {
        VStack(spacing:6) {
            HStack {
                if !model.document.annotations.isEmpty {
                    Picker(tr("Annotation object"),selection:Binding(get:{ model.selectedAnnotation ?? -1 },set:{ model.selectAnnotation($0 < 0 ? nil : $0);if $0 >= 0 { model.tool = .select } })) {
                        Text(tr("No selection")).tag(-1)
                        ForEach(Array(model.document.annotations.enumerated()),id:\.offset) { index,item in Text("\(index+1). "+tr(item.tool.label)).tag(index) }
                    }.frame(maxWidth:220)
                }
                if tool == .mosaic || tool == .blur {
                    Text(tr(tool == .mosaic ? "Mosaic block size" : "Blur radius"))
                    Slider(value:$model.annotationOptions.strength,in:1...128).frame(width:160)
                }
                if tool == .magnifier {
                    Text(tr("Magnification"));Slider(value:$model.annotationOptions.zoom,in:1...8).frame(width:130)
                }
                if [.spotlight,.magnifier].contains(tool) { Toggle(tr("Ellipse region"),isOn:$model.annotationOptions.ellipse) }
                if [.spotlight,.watermark].contains(tool) {
                    Text(tr("Effect opacity"));Slider(value:$model.annotationOptions.opacity,in:0...1).frame(width:100)
                }
                if tool == .watermark { Text(tr("Watermark angle"));Slider(value:$model.annotationOptions.angle,in:-90...90).frame(width:100) }
                Spacer()
                if model.selectedAnnotation != nil { Button(tr("Delete selected annotation")) { model.deleteSelected() } }
                Button(tr("Clear annotations")) { model.document.clearAnnotations();model.selectedAnnotation=nil }.disabled(model.document.annotations.isEmpty)
            }
            if model.selectedAnnotation != nil,[CaptureTool.text,.watermark,.number].contains(tool) { TextField(tr("Annotation text"),text:$model.text).textFieldStyle(.roundedBorder) }
        }.padding(.horizontal,10)
            .onChange(of:model.color) { _ in model.applySelectedStyle() }
            .onChange(of:model.lineWidth) { _ in model.applySelectedStyle() }
            .onChange(of:model.text) { _ in model.applySelectedStyle() }
            .onChange(of:model.annotationOptions) { _ in model.applySelectedStyle() }
    }
}
