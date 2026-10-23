import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n

extension CaptureCanvas.Canvas {
    func cancelConnectedLine() {
        if connectedLineOwner != nil {draft=nil}
        connectedLineVertices=[];connectedLineRevision=nil;connectedLineOwner=nil;needsDisplay=true
    }
    func reconcileConnectedLine() {
        guard connectedLineOwner != nil else{return}
        if connectedLineOwner != ObjectIdentifier(model) || connectedLineRevision != model.revision || model.locked || model.tool != .line || !model.connectedLine || model.selectingOCRText {
            cancelConnectedLine()
        } else {
            draft?.color=NSColor(model.color);draft?.width=model.lineWidth
            var options=model.annotationOptions;options.arrowComment="";draft?.options=options
        }
    }
    func handleConnectedLineClick(_ event:NSEvent) -> Bool {
        reconcileConnectedLine()
        guard model.tool == .line,model.connectedLine,!model.locked,!model.selectingOCRText,scale > 0 else{return false}
        guard imageRect.contains(convert(event.locationInWindow,from:nil)) else{return true}
        cancelSelectionGesture();model.selectAnnotations([])
        var p=point(event)
        if event.modifierFlags.contains(.shift),let previous=connectedLineVertices.last {p=CaptureAnnotation.snappedEndpoint(from:previous,to:p,inside:model.document.size)}
        if connectedLineVertices.isEmpty {
            connectedLineOwner=ObjectIdentifier(model);connectedLineRevision=model.revision;connectedLineVertices=[p]
            var options=model.annotationOptions;options.arrowComment=""
            draft=CaptureAnnotation(tool:.line,points:[p,p],color:NSColor(model.color),width:model.lineWidth,options:options)
        } else {
            if let last=connectedLineVertices.last,hypot(p.x-last.x,p.y-last.y)>0.01 {
                guard connectedLineVertices.count < 4096 else {model.error=tr("A connected line can contain up to 4096 points.");return true}
                connectedLineVertices.append(p)
            }
            if event.clickCount>=2 {finishConnectedLine();return true}
            draft?.points=connectedLineVertices+[p]
        }
        needsDisplay=true;return true
    }
    @discardableResult func updateConnectedLinePreview(_ event:NSEvent) -> Bool {
        reconcileConnectedLine()
        guard !connectedLineVertices.isEmpty,let previous=connectedLineVertices.last else{return false}
        var p=point(event)
        if event.modifierFlags.contains(.shift) {p=CaptureAnnotation.snappedEndpoint(from:previous,to:p,inside:model.document.size)}
        draft?.points=connectedLineVertices+[p];needsDisplay=true;return true
    }
    func finishConnectedLine() {
        reconcileConnectedLine()
        guard connectedLineVertices.count>=2,var item=draft else{return}
        item.points=connectedLineVertices
        cancelConnectedLine();model.document.append(item);model.error=nil
    }
    func handleConnectedLineKey(_ event:NSEvent) -> Bool {
        reconcileConnectedLine()
        guard !connectedLineVertices.isEmpty else{return false}
        if event.keyCode == 53 {cancelConnectedLine();return true}
        guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty else{return false}
        if event.keyCode == 36 || event.keyCode == 76 {finishConnectedLine();return true}
        if event.keyCode == 51 || event.keyCode == 117 {
            connectedLineVertices.removeLast()
            if let last=connectedLineVertices.last {draft?.points=connectedLineVertices+[last];needsDisplay=true}
            else {cancelConnectedLine()}
            return true
        }
        return false
    }
}
