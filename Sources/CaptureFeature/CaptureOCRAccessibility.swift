import AppKit
import CaptureCore

final class CaptureOCRAccessibilityElement:NSAccessibilityElement {
    private weak var canvas:CaptureCanvas.Canvas?
    let index:Int
    private let segment:CaptureTextSegment
    private let text:String
    init(canvas:CaptureCanvas.Canvas,index:Int,segment:CaptureTextSegment,label:String) {
        self.canvas=canvas;self.index=index;self.segment=segment;self.text=label;super.init()
        setAccessibilityElement(true);setAccessibilityEnabled(true)
        setAccessibilityRole(.checkBox);setAccessibilityLabel(label);setAccessibilityIdentifier("capture-ocr-\(index)");setAccessibilityParent(canvas)
    }
    override func accessibilityPerformPress() -> Bool {
        MainActor.assumeIsolated {
            guard let canvas,canvas.model.selectingOCRText,canvas.model.ocrSegments.indices.contains(index),canvas.model.ocrSegments[index] == segment,
                  let range=Range(segment.range,in:canvas.model.recognition),String(canvas.model.recognition[range]) == text else {return false}
            if canvas.model.selectedOCRSegments.contains(index) {canvas.model.selectedOCRSegments.remove(index)} else {canvas.model.selectedOCRSegments.insert(index)}
            setAccessibilityValue(NSNumber(value:canvas.model.selectedOCRSegments.contains(index)))
            canvas.window?.makeFirstResponder(canvas);canvas.needsDisplay=true
            NSAccessibility.post(element:self,notification:.valueChanged);return true
        }
    }
}
