import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers

struct CaptureLaTeXPinView:View {
    @ObservedObject var model:CaptureEditorModel
    let formula:CaptureLaTeX
    @State private var draft=""
    private func apply(_ next:CaptureLaTeX? = nil) {
        var value=next ?? formula;value.source=draft
        do { try model.updatePinContent(.latex(value));model.error=nil }
        catch { model.error=captureFailureMessage(error) }
    }
    var body:some View {
        VStack(spacing:10) {
            ScrollView([.horizontal,.vertical]) {
                Image(decorative:model.document.image,scale:2).resizable().interpolation(.high)
                    .frame(width:CGFloat(model.document.image.width)/2*model.zoom,height:CGFloat(model.document.image.height)/2*model.zoom)
                    .padding(20)
                    .onDrag {
                        let data=NSBitmapImageRep(cgImage:model.document.image).representation(using:.png,properties:[:]) ?? Data()
                        return NSItemProvider(item:data as NSData,typeIdentifier:UTType.png.identifier)
                    }
            }.frame(maxWidth:.infinity,maxHeight:.infinity).background(Color.white)
            TextEditor(text:$draft).font(.system(size:14,design:.monospaced)).frame(height:135).border(Color.secondary.opacity(0.3))
                .onChange(of:draft) { value in
                    if value != formula.source {
                        let message=tr("Apply or revert the formula edits before closing.")
                        model.pinContentSaveError=message;model.error=message
                    } else { model.pinContentSaveError=nil;model.error=nil }
                }
            HStack {
                Button(tr("Apply formula")) { apply() }
                Toggle(tr("Display formula"),isOn:Binding(get:{ formula.display },set:{ var value=formula;value.display=$0;apply(value) }))
                Stepper(tr("Font size")+" \(Int(formula.fontSize))",value:Binding(get:{ formula.fontSize },set:{ var value=formula;value.fontSize=$0;apply(value) }),in:8...96).fixedSize()
                ColorPicker(tr("Formula color"),selection:Binding(get:{ Color(nsColor:CapturePinColor.parse(formula.foreground)!.nsColor) },set:{ color in var value=formula;value.foreground=hex(color);apply(value) }),supportsOpacity:false)
                Toggle(tr("Transparent background"),isOn:Binding(get:{ formula.transparentBackground },set:{ var value=formula;value.transparentBackground=$0;apply(value) }))
            }
            if !formula.transparentBackground { ColorPicker(tr("Formula background"),selection:Binding(get:{ Color(nsColor:CapturePinColor.parse(formula.background)!.nsColor) },set:{ color in var value=formula;value.background=hex(color);apply(value) }),supportsOpacity:false) }
            HStack {
                Button(tr("Copy LaTeX source")) { NSPasteboard.general.clearContents();NSPasteboard.general.setString(draft,forType:.string) }
                Button(tr("Copy MathML")) { copyMathML() }.disabled(model.pinContentSaveError != nil)
                Button(tr("Copy SVG")) { copySVG() }.disabled(model.pinContentSaveError != nil)
                Button(tr("Export SVG…")) { exportSVG() }.disabled(model.pinContentSaveError != nil)
                Slider(value:$model.zoom,in:0.25...4).frame(width:85).disabled(model.locked).help(tr("Zoom"))
            }
        }.padding(.horizontal,10).onAppear { draft=formula.source }
    }
    private func hex(_ value:Color) -> String {
        let color=NSColor(value).usingColorSpace(.sRGB) ?? .black
        return String(format:"#%02X%02X%02X",Int((color.redComponent*255).rounded()),Int((color.greenComponent*255).rounded()),Int((color.blueComponent*255).rounded()))
    }
    private func copyMathML() {
        do { try CapturePinClipboard.copyFormula(formula,format:.mathml,to:.general) }
        catch { model.error=captureFailureMessage(error) }
    }
    private func copySVG() {
        do { try CapturePinClipboard.copyFormula(formula,format:.svg,to:.general) }
        catch { model.error=captureFailureMessage(error) }
    }
    private func exportSVG() {
        do {
            let output=try formula.render(),panel=NSSavePanel();panel.allowedContentTypes=[.svg];panel.nameFieldStringValue="Thermo-formula.svg"
            guard panel.runModal() == .OK,let url=panel.url else { return }
            try Data(output.svg.utf8).write(to:url,options:.atomic)
        } catch { model.error=captureFailureMessage(error) }
    }
}
