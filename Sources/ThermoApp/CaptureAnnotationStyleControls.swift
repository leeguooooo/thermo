import CaptureCore
import SwiftUI
import ThermoL10n

struct CaptureAnnotationStyleControls:View {
    @ObservedObject var model:CaptureEditorModel
    let tool:CaptureTool
    private var numberValue:Binding<Int> {
        Binding(get:{model.selectedAnnotation != nil ? model.annotationOptions.numberValue ?? Int(model.text) ?? 1 : model.nextSequenceNumber},set:{value in
            guard (1...3999).contains(value) else{return}
            if model.selectedAnnotation != nil {model.annotationOptions.numberValue=value} else {model.nextSequenceNumber=value}
        })
    }
    var body:some View {
        ScrollView(.horizontal,showsIndicators:true) { HStack {
            if tool == .number {
                Picker(tr("Sequence format"),selection:Binding(get:{model.annotationOptions.numberFormat},set:{value in
                    if model.selectedAnnotation != nil,model.annotationOptions.numberValue == nil {model.annotationOptions.numberValue=min(3999,max(1,Int(model.text) ?? 1))}
                    model.annotationOptions.numberFormat=value
                })) {
                    Text(tr("Numbers (1, 2, 3)")).tag(CaptureNumberFormat.decimal)
                    Text(tr("Letters (A, B, C)")).tag(CaptureNumberFormat.alphabetic)
                    Text(tr("Roman numerals (I, II, III)")).tag(CaptureNumberFormat.roman)
                }.frame(width:230)
                Text(tr(model.selectedAnnotation == nil ? "Next sequence number" : "Sequence value"))
                TextField(tr("Sequence value"),value:numberValue,format:.number).frame(width:60)
                Stepper("",value:numberValue,in:1...3999).labelsHidden()
                Picker(tr("Sequence shape"),selection:$model.annotationOptions.numberShape) {
                    Text(tr("Circle badge")).tag(CaptureNumberShape.circle)
                    Text(tr("Square badge")).tag(CaptureNumberShape.square)
                }.frame(width:150)
                Toggle(tr("Filled badge"),isOn:$model.annotationOptions.numberFilled)
                Toggle(tr("Sequence leader"),isOn:$model.annotationOptions.numberLeader)
            }
            if tool == .arrow {
                headPicker("Start marker",value:$model.annotationOptions.arrowStart)
                headPicker("End marker",value:$model.annotationOptions.arrowEnd)
            }
            Picker(tr("Line pattern"),selection:$model.annotationOptions.linePattern) {
                Text(tr("Solid line")).tag(CaptureLinePattern.solid)
                Text(tr("Dashed line")).tag(CaptureLinePattern.dashed)
                Text(tr("Dotted line")).tag(CaptureLinePattern.dotted)
            }.frame(width:165)
            if tool == .number {headPicker("Leader marker",value:$model.annotationOptions.arrowEnd)}
        }.font(.caption) }.frame(height:32)
    }
    private func headPicker(_ title:String,value:Binding<CaptureArrowHead>) -> some View {
        Picker(tr(title),selection:value) {
            Text(tr("No marker")).tag(CaptureArrowHead.none)
            Text(tr("Open arrowhead")).tag(CaptureArrowHead.open)
            Text(tr("Filled arrowhead")).tag(CaptureArrowHead.filled)
            Text(tr("Diamond marker")).tag(CaptureArrowHead.diamond)
            Text(tr("Circle marker")).tag(CaptureArrowHead.circle)
        }.frame(width:175)
    }
}
