import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n

@MainActor extension CaptureEditorModel {
    func setCropSelection(_ requested:CGRect) {
        guard !locked,tool == .crop,!selectingOCRText,
              [requested.origin.x,requested.origin.y,requested.width,requested.height].allSatisfy({$0.isFinite}) else {return}
        let rect=requested.standardized.intersection(CGRect(origin:.zero,size:document.size)).integral
        cropSelection = !rect.isNull && rect.width >= 1 && rect.height >= 1 ? rect : nil
    }
    func moveCrop(from rect:CGRect,dx:CGFloat,dy:CGFloat) {
        guard dx.isFinite,dy.isFinite else{return}
        setCropSelection(CGRect(x:min(max(0,(rect.minX+dx).rounded()),document.size.width-rect.width),
                                y:min(max(0,(rect.minY+dy).rounded()),document.size.height-rect.height),width:rect.width,height:rect.height))
    }
    func resizeCrop(width:Double?=nil,height:Double?=nil) {
        guard let rect=cropSelection else{return}
        let w=width ?? rect.width,h=height ?? rect.height
        guard w.isFinite,h.isFinite else{return}
        setCropSelection(CGRect(x:rect.minX,y:rect.minY,width:min(max(1,w.rounded()),document.size.width-rect.minX),height:min(max(1,h.rounded()),document.size.height-rect.minY)))
    }
    func commitCrop() {
        guard !locked,tool == .crop,let rect=cropSelection else{return}
        do {try document.crop(to:rect);pan = .zero;selectAnnotations([]);error=nil}
        catch {self.error=tr(error.localizedDescription)}
    }
}

struct CaptureCropControls:View {
    @ObservedObject var model:CaptureEditorModel
    var body:some View {
        HStack {
            if let rect=model.cropSelection {
                Text(tr("Crop width"))
                TextField(tr("Crop width"),value:Binding(get:{Double(model.cropSelection?.width ?? 1)},set:{model.resizeCrop(width:$0)}),format:.number.precision(.fractionLength(0))).frame(width:70)
                Text(tr("Crop height"))
                TextField(tr("Crop height"),value:Binding(get:{Double(model.cropSelection?.height ?? 1)},set:{model.resizeCrop(height:$0)}),format:.number.precision(.fractionLength(0))).frame(width:70)
                Text("\(Int(rect.width)) × \(Int(rect.height)) px").font(.caption)
                Button(tr("Apply crop")){model.commitCrop()}
                Button(tr("Cancel crop")){model.cropSelection=nil}
            }
            Text(tr("Drag to select. Move inside or resize the corner. Arrows move 1 px; Shift moves 10. Return applies; Esc cancels."))
                .font(.caption).foregroundStyle(.secondary)
        }.padding(8)
    }
}
