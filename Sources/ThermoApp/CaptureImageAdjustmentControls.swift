import CaptureCore
import SwiftUI
import ThermoL10n

@MainActor extension CaptureEditorModel {
    func setImageAdjustments(_ next:CaptureImageAdjustments) throws {
        try requireEditable()
        guard pinContent == nil else {throw CaptureActionFailure.imageRequired}
        guard next != document.imageAdjustments else{return}
        try document.applyImageAdjustments(next)
    }
    func applyColorAction(_ action:CaptureAction) throws {
        var next=document.imageAdjustments
        switch action {
        case .grayscale:next.grayscale.toggle()
        case .invert:next.inverted.toggle()
        case .brightnessUp:next.brightness=min(20,(next.brightness*10).rounded()+1)/10
        case .brightnessDown:next.brightness=max(0,(next.brightness*10).rounded()-1)/10
        case .resetImageAdjustments:next = .init()
        default:return
        }
        try setImageAdjustments(next)
    }
}

struct CaptureImageAdjustmentControls:View {
    @ObservedObject var model:CaptureEditorModel
    private func apply(_ action:CaptureAction) {
        do {try model.applyColorAction(action);model.error=nil} catch {model.error=captureFailureMessage(error)}
    }
    private func commit(_ next:CaptureImageAdjustments) {
        do {try model.setImageAdjustments(next);model.error=nil} catch {model.error=captureFailureMessage(error)}
    }
    var body:some View {
        HStack {
            Toggle(tr("Grayscale image"),isOn:Binding(get:{model.document.imageAdjustments.grayscale},set:{value in var next=model.document.imageAdjustments;next.grayscale=value;commit(next)}))
            Toggle(tr("Invert image colors"),isOn:Binding(get:{model.document.imageAdjustments.inverted},set:{value in var next=model.document.imageAdjustments;next.inverted=value;commit(next)}))
            Text(tr("Image brightness"))
            Button {apply(.brightnessDown)} label:{Image(systemName:"minus")}.accessibilityLabel(tr("Decrease image brightness"))
                .disabled(model.document.imageAdjustments.brightness<=0)
            Text("\(Int((model.document.imageAdjustments.brightness*100).rounded()))%").monospacedDigit().frame(width:48)
            Button {apply(.brightnessUp)} label:{Image(systemName:"plus")}.accessibilityLabel(tr("Increase image brightness"))
                .disabled(model.document.imageAdjustments.brightness>=2)
            Button(tr("Reset color adjustments")){apply(.resetImageAdjustments)}.disabled(model.document.imageAdjustments.isDefault)
            Spacer()
        }.font(.caption).padding(.horizontal,10).padding(.vertical,4)
    }
}
