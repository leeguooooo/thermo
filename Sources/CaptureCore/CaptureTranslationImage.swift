import AppKit
import Vision

public struct CaptureTranslationRegion:Sendable,Identifiable,Equatable {
    public var id=UUID()
    public var text:String
    /// Vision normalized coordinates, origin at bottom left.
    public var bounds:CGRect
    public init(text:String,bounds:CGRect){self.text=text;self.bounds=bounds}
}
public enum CaptureTranslationImage {
    public static func recognize(_ image:CGImage)throws->[CaptureTranslationRegion] {
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.usesLanguageCorrection=true;request.automaticallyDetectsLanguage=true
        try VNImageRequestHandler(cgImage:image).perform([request])
        let result=(request.results ?? []).compactMap{observation->CaptureTranslationRegion? in guard let text=observation.topCandidates(1).first?.string,!text.isEmpty else{return nil};return .init(text:text,bounds:observation.boundingBox)}
        guard !result.isEmpty else{throw CaptureTranslationFailure.invalidInput};guard result.count<=256 else{throw CaptureTranslationFailure.tooLarge};return result
    }
    public static func overlay(_ image:CGImage,regions:[CaptureTranslationRegion],translations:[String])throws->CGImage {
        guard !regions.isEmpty,regions.count == translations.count,image.width<=80_000_000/max(1,image.height),let ctx=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw CaptureTranslationFailure.invalidInput}
        ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(cgContext:ctx,flipped:false);defer{NSGraphicsContext.restoreGraphicsState()}
        for (region,text) in zip(regions,translations) {
            let box=region.bounds
            guard [box.minX,box.minY,box.width,box.height].allSatisfy(\.isFinite),box.width>0,box.height>0,box.minX>=0,box.minY>=0,box.maxX<=1,box.maxY<=1,!text.isEmpty,text.utf8.count<=256_000 else{throw CaptureTranslationFailure.invalidInput}
            let rect=CGRect(x:box.minX*CGFloat(image.width),y:box.minY*CGFloat(image.height),width:box.width*CGFloat(image.width),height:box.height*CGFloat(image.height)).insetBy(dx:-1,dy:-1).intersection(CGRect(x:0,y:0,width:image.width,height:image.height))
            let paragraph=NSMutableParagraphStyle();paragraph.lineBreakMode = .byWordWrapping
            var fontSize=min(96,max(6,rect.height*0.8)),attributes:[NSAttributedString.Key:Any]=[:]
            while true {
                attributes=[.font:NSFont.systemFont(ofSize:fontSize),.foregroundColor:NSColor.black,.paragraphStyle:paragraph]
                let measured=(text as NSString).boundingRect(with:NSSize(width:rect.width,height:.greatestFiniteMagnitude),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:attributes)
                if measured.height<=rect.height && measured.width<=rect.width+0.5{break};fontSize -= 0.5;guard fontSize>=6 else{throw CaptureTranslationFailure.doesNotFit}
            }
            ctx.setFillColor(NSColor.white.cgColor);ctx.fill(rect);(text as NSString).draw(in:rect,withAttributes:attributes)
        }
        guard let result=ctx.makeImage() else{throw CaptureFailure.exportFailed};return result
    }
}
