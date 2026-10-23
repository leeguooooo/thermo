import AppKit
import CaptureCore

extension CaptureEditorModel {
    var selectedOCRText:String {CaptureTextSelection.text(in:recognition,segments:ocrSegments,selected:selectedOCRSegments)}
    @discardableResult func copyOCRText(to destination:NSPasteboard? = nil) -> Bool {
        let text=selectedOCRSegments.isEmpty ? recognition : selectedOCRText
        guard !text.isEmpty else {return false}
        let board=destination ?? copyPasteboard ?? .general
        board.clearContents();return board.setString(text,forType:.string)
    }
    func ocrRect(_ index:Int) -> CGRect {
        let box=ocrSegments[index].bounds
        return CGRect(x:box.minX*document.size.width,y:box.minY*document.size.height,width:box.width*document.size.width,height:box.height*document.size.height)
    }
}
