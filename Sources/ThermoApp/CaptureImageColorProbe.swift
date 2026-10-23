import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n

@MainActor extension CaptureEditorModel {
    func copyPixelColor() {
        guard let pickedImagePixel else{return}
        let board=copyPasteboard ?? .general,value=pickedImagePixel.color.formatted(pixelColorFormat)
        board.clearContents();board.setString(value,forType:.string)
    }
    func cyclePixelColorFormat() {
        let formats:[CapturePinColor.Format]=[.rgb,.hex,.rgba,.hsl,.hsv]
        let index=formats.firstIndex(of:pixelColorFormat) ?? 0;pixelColorFormat=formats[(index+1)%formats.count]
    }
}
struct CaptureImageColorProbeControls:View {
    @ObservedObject var model:CaptureEditorModel
    var body:some View {
        VStack(alignment:.leading,spacing:2) {
            ScrollView(.horizontal,showsIndicators:false) {HStack {
            Toggle(tr("Pick image color"),isOn:$model.pickingImageColor)
            Picker(tr("Pixel color format"),selection:$model.pixelColorFormat) {ForEach(CapturePinColor.Format.allCases,id:\.self){Text($0.rawValue).tag($0)}}.frame(width:140)
            if let pixel=model.pickedImagePixel {
                RoundedRectangle(cornerRadius:3).fill(Color(nsColor:pixel.color.nsColor)).frame(width:22,height:20).overlay(RoundedRectangle(cornerRadius:3).stroke(.secondary))
                Text("x:\(pixel.x), y:\(pixel.y)").monospacedDigit().font(.caption)
                Text(pixel.color.formatted(model.pixelColorFormat)).font(.system(.caption,design:.monospaced)).textSelection(.enabled)
                Button(tr("Copy pixel color")){model.copyPixelColor()}
            }
            }}.frame(height:28)
            Text(tr("Hover or click to sample. C copies; Shift changes format; Option temporarily picks; Esc exits.")).font(.caption).foregroundStyle(.secondary)
        }.padding(.horizontal,10).padding(.vertical,4)
    }
}

extension CaptureCanvas.Canvas {
    var colorProbeActive:Bool {model.pickingImageColor || colorOptionHeld}
    func clearColorProbeImage() {colorProbeImage=nil;colorProbeRevision=nil;colorProbeSource=nil}
    func reconcileColorProbe() {
        if colorProbeActive,!colorProbeWasActive {beginColorProbe()}
        colorProbeWasActive=colorProbeActive
        if !colorProbeActive || colorProbeSource != ObjectIdentifier(model) || colorProbeRevision != model.revision {clearColorProbeImage()}
    }
    func beginColorProbe() {
        cancelSelectionGesture();cancelConnectedLine();draft=nil;cropDragStart=nil;cropDragOriginal=nil;lastDrag=nil;ocrDragStart=nil
    }
    func updateColorProbeModifiers(_ event:NSEvent,cycleShift:Bool) {
        let wasActive=colorProbeActive,wasOption=colorOptionHeld,wasShift=colorShiftHeld
        colorOptionHeld=event.modifierFlags.contains(.option) && event.modifierFlags.intersection([.command,.control]).isEmpty
        colorShiftHeld=event.modifierFlags.contains(.shift)
        if cycleShift,colorProbeActive,!wasShift,colorShiftHeld {model.cyclePixelColorFormat()}
        reconcileColorProbe()
        if wasActive != colorProbeActive || wasOption != colorOptionHeld || wasShift != colorShiftHeld {needsDisplay=true}
    }
    @discardableResult func sampleImageColor(at point:CGPoint) -> Bool {
        guard colorProbeActive,scale.isFinite,scale>0,point.x.isFinite,point.y.isFinite,bounds.contains(point),imageRect.contains(point) else{return false}
        let x=Int(floor((point.x-imageRect.minX)/scale)),bottomY=Int(floor((point.y-imageRect.minY)/scale))
        do {
            reconcileColorProbe()
            let image:CGImage
            if let cached=colorProbeImage {image=cached}
            else {
                guard model.document.image.height>0,model.document.image.width<=80000000/model.document.image.height else {throw CaptureFailure.invalidImage}
                image=try confirmedImage();colorProbeImage=image;colorProbeRevision=model.revision;colorProbeSource=ObjectIdentifier(model)
            }
            let pixel=try CaptureImagePixelReader.read(image,x:x,y:image.height-1-bottomY)
            if model.pickedImagePixel != pixel {model.pickedImagePixel=pixel}
        } catch {model.error=tr(error.localizedDescription)}
        needsDisplay=true;return true
    }
    func handleColorProbePointer(_ event:NSEvent) -> Bool {
        updateColorProbeModifiers(event,cycleShift:false)
        guard colorProbeActive else{return false}
        _=sampleImageColor(at:convert(event.locationInWindow,from:nil));return true
    }
    func handleColorProbeKey(_ event:NSEvent) -> Bool {
        guard colorProbeActive else{return false}
        if event.keyCode==53 {model.pickingImageColor=false;colorOptionHeld=false;model.pickedImagePixel=nil;clearColorProbeImage();needsDisplay=true;return true}
        if event.keyCode==51 || event.keyCode==117 {return true}
        if event.keyCode==8,event.modifierFlags.intersection([.command,.control]).isEmpty {model.copyPixelColor();return true}
        return false
    }
    func drawColorProbe(in context:CGContext) {
        guard colorProbeActive,let pixel=model.pickedImagePixel,let image=colorProbeImage else{return}
        let bottomY=image.height-1-pixel.y,p=CGPoint(x:imageRect.minX+(CGFloat(pixel.x)+0.5)*scale,y:imageRect.minY+(CGFloat(bottomY)+0.5)*scale)
        let panel=CGRect(x:min(max(6,p.x+14),max(6,bounds.width-142)),y:min(max(6,p.y+14),max(6,bounds.height-142)),width:136,height:136)
        let x=max(0,pixel.x-6),y=max(0,pixel.y-6),right=min(image.width,pixel.x+7),bottom=min(image.height,pixel.y+7)
        guard let patch=image.cropping(to:CGRect(x:x,y:y,width:right-x,height:bottom-y)) else{return}
        context.saveGState();defer{context.restoreGState()};context.clip(to:bounds)
        context.setFillColor(NSColor.windowBackgroundColor.withAlphaComponent(0.95).cgColor);context.fill(panel)
        let dest=CGRect(x:panel.midX-CGFloat(patch.width)*4,y:panel.minY+25,width:CGFloat(patch.width)*8,height:CGFloat(patch.height)*8)
        context.interpolationQuality = .none;context.draw(patch,in:dest)
        let mark=CGRect(x:dest.minX+CGFloat(pixel.x-x)*8,y:dest.minY+CGFloat(bottom-1-pixel.y)*8,width:8,height:8)
        context.setStrokeColor(NSColor.white.cgColor);context.setLineWidth(3);context.stroke(mark)
        context.setStrokeColor(NSColor.black.cgColor);context.setLineWidth(1);context.stroke(mark)
        context.setStrokeColor(NSColor.labelColor.cgColor);context.stroke(panel)
        (pixel.color.formatted(.hex) as NSString).draw(at:CGPoint(x:panel.minX+8,y:panel.minY+6),withAttributes:[.font:NSFont.monospacedSystemFont(ofSize:11,weight:.regular),.foregroundColor:NSColor.labelColor])
    }
}
