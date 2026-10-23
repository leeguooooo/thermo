import AppKit
import CaptureCore

enum CaptureDisplayFailure: LocalizedError {
    case unavailable, changed, invalidRegion
    var errorDescription: String? {
        switch self {
        case .unavailable: return "The selected display was disconnected. Select a recording region again."
        case .changed: return "The selected display size or scale changed. Select a recording region again."
        case .invalidRegion: return "The capture region is outside the selected display. Select a region again."
        }
    }
}

extension CaptureRegionSelector.Region {
    /// Display-local top-left points. Display origins may move without invalidating this rectangle.
    func validate(displaySize: CGSize, scale currentScale: CGFloat) throws {
        let values=[rect.minX,rect.minY,rect.width,rect.height,displaySize.width,displaySize.height,scale,currentScale]
        guard values.allSatisfy(\.isFinite), scale>0,currentScale>0,rect.width>=32,rect.height>=32,
              CGRect(origin:.zero,size:displaySize).contains(rect) else {throw CaptureDisplayFailure.invalidRegion}
        if let selectedDisplaySize,selectedDisplaySize != displaySize {throw CaptureDisplayFailure.changed}
        guard abs(scale-currentScale)<0.001 else {throw CaptureDisplayFailure.changed}
    }
    func validateCurrentDisplay() throws {
        guard let screen=NSScreen.screens.first(where: {($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32)==displayID}) else {throw CaptureDisplayFailure.unavailable}
        try validate(displaySize:screen.frame.size,scale:screen.backingScaleFactor)
    }
    func recordingPixelSize() throws -> (width:Int,height:Int) {
        let values=[rect.width,rect.height,scale]
        guard values.allSatisfy(\.isFinite),rect.width>=32,rect.height>=32,scale>0 else {throw CaptureDisplayFailure.invalidRegion}
        let factor=min(scale,4096/max(rect.width,rect.height))
        return (max(2,Int(rect.width*factor)/2*2),max(2,Int(rect.height*factor)/2*2))
    }
    func normalizedPointer(_ point:CGPoint,displayFrame:CGRect) -> CGPoint? {
        guard [point.x,point.y,displayFrame.minX,displayFrame.minY,rect.width,rect.height].allSatisfy(\.isFinite),rect.width>0,rect.height>0 else {return nil}
        let x=(point.x-displayFrame.minX-rect.minX)/rect.width
        let y=1-(point.y-displayFrame.minY-rect.minY)/rect.height
        guard (0...1).contains(x),(0...1).contains(y) else {return nil}
        return CGPoint(x:x,y:y)
    }
}
