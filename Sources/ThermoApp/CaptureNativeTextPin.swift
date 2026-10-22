import AppKit
import CaptureCore
import SwiftUI

struct CaptureNativeTextPin:NSViewRepresentable {
    let text:CapturePinText
    let editable:Bool
    let model:CaptureEditorModel
    let onChange:(CapturePinText)->Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSScrollView {
        let scroll=NSScrollView();scroll.hasVerticalScroller=true;scroll.drawsBackground=true
        let view=NSTextView(frame:scroll.bounds);view.isVerticallyResizable=true;view.isHorizontallyResizable=false;view.autoresizingMask=[.width];view.textContainer?.widthTracksTextView=true
        view.textContainer?.containerSize=CGSize(width:0,height:CGFloat.greatestFiniteMagnitude);view.textContainerInset=CGSize(width:16,height:16)
        view.isSelectable=true;view.allowsUndo=true;view.isAutomaticLinkDetectionEnabled=false;view.delegate=context.coordinator;scroll.documentView=view
        model.snapshotPinContent={ [weak view] in
            guard let view,view.visibleRect.width > 0,view.visibleRect.height > 0,let rep=view.bitmapImageRepForCachingDisplay(in:view.visibleRect) else { throw CaptureFailure.invalidImage }
            view.cacheDisplay(in:view.visibleRect,to:rep);guard let image=rep.cgImage else { throw CaptureFailure.invalidImage };return image
        }
        return scroll
    }
    func updateNSView(_ scroll:NSScrollView,context:Context) {
        guard let view=scroll.documentView as? NSTextView else { return }
        context.coordinator.parent=self;scroll.allowsMagnification = !model.locked;scroll.minMagnification=0.25;scroll.maxMagnification=4;if abs(scroll.magnification-model.zoom) > 0.001 { scroll.magnification=model.zoom };view.isEditable=editable;view.isRichText = !text.ignoreFormatting
        view.backgroundColor=CapturePinText.color(text.background)
        if context.coordinator.value != text {
            do { let attributed=try text.attributed();view.textStorage?.setAttributedString(attributed);context.coordinator.value=text }
            catch { DispatchQueue.main.async { model.error=error.localizedDescription } }
        }
    }
    final class Coordinator:NSObject,NSTextViewDelegate {
        var parent:CaptureNativeTextPin
        var value:CapturePinText?
        init(_ parent:CaptureNativeTextPin) { self.parent=parent }
        func textDidChange(_ notification:Notification) {
            guard let view=notification.object as? NSTextView,let storage=view.textStorage else { return }
            var next=parent.text;next.plain=storage.string;next.html=nil
            next.rtf=try? storage.data(from:NSRange(location:0,length:storage.length),documentAttributes:[.documentType:NSAttributedString.DocumentType.rtf])
            guard next.valid else { let message=CapturePinFailure.invalidContent.localizedDescription;parent.model.pinContentSaveError=message;parent.model.error=message;return }
            value=next;parent.onChange(next)
        }
    }
}
