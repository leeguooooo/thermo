import AppKit

/// Fixed edges are separate from document content. State commits only after unique alignment.
public struct CaptureScrollStitcher {
    public struct Result {
        public let image:CGImage
        public let duplicate:Bool
        public let fixedLeading:Int
        public let fixedTrailing:Int
        public let viewportOffset:Int
    }
    private let horizontal:Bool
    private let automatic:Bool
    private let configuredLeading:Int
    private let configuredTrailing:Int
    private var first:CGImage?
    private var last:CGImage?
    private var content:CGImage?
    private var output:CGImage?
    private var edges:(Int,Int)?
    private var offset=0
    public init(direction:CaptureStitcher.Direction = .vertical,detectFixedEdges:Bool=true,leadingInset:Int=0,trailingInset:Int=0) {
        horizontal=direction == .horizontal;automatic=detectFixedEdges
        configuredLeading=leadingInset;configuredTrailing=trailingInset
    }
    public mutating func append(_ frame:CGImage) throws -> Result {
        guard frame.width > 0,frame.height >= 1,frame.width <= 80_000_000/frame.height else {throw StitchFailure.tooLarge}
        let next=horizontal ? try CaptureStitcher.transposed(frame) : frame
        guard next.height >= 32 else {throw StitchFailure.fixedEdges}
        guard let first,let last,let output else {
            let initial=automatic ? (0,0) : (configuredLeading,configuredTrailing)
            try validate(initial,height:next.height)
            let body=try crop(next,leading:initial.0,trailing:initial.1)
            self.first=next;self.last=next;self.output=frame
            if !automatic {edges=initial;content=body}
            return .init(image:frame,duplicate:false,fixedLeading:initial.0,fixedTrailing:initial.1,viewportOffset:0)
        }
        guard next.width == first.width,next.height == first.height else {throw StitchFailure.viewportChanged}
        let nextPixels=try CaptureStitcher.pixels(next),lastPixels=try CaptureStitcher.pixels(last)
        if nextPixels == lastPixels {return result(output,duplicate:true)}
        let proposed=try edges ?? detect(lastPixels,nextPixels,width:next.width,height:next.height)
        try validate(proposed,height:next.height)
        let body=try crop(next,leading:proposed.0,trailing:proposed.1)
        let previous=try content ?? crop(first,leading:proposed.0,trailing:proposed.1)
        if let found=try contained(body,in:previous) {
            self.last=next;self.offset=found;self.edges=proposed;self.content=previous
            return result(output,duplicate:true)
        }
        func match(_ a:CGImage,_ b:CGImage) throws -> CaptureStitcher.Result? {
            do {return try CaptureStitcher.append(b,to:a)}
            catch StitchFailure.noOverlap {return nil}
            catch StitchFailure.blankOverlap {return nil}
        }
        let forward=try match(previous,body),backward=try match(body,previous)
        // A cyclic/repeated pattern can align in both directions. Do not guess.
        guard (forward == nil) != (backward == nil) else {throw StitchFailure.noOverlap}
        let joined=forward ?? backward!
        let nextOffset=forward != nil ? joined.image.height-body.height : 0
        let composed=try compose(joined.image,first:first,last:next,edges:proposed)
        let nextContent=try crop(composed,leading:proposed.0,trailing:proposed.1)
        let image=horizontal ? try CaptureStitcher.transposed(composed) : composed
        self.last=next;self.edges=proposed;self.content=nextContent;self.output=image;self.offset=nextOffset
        return result(image,duplicate:joined.duplicate)
    }
    private func result(_ image:CGImage,duplicate:Bool) -> Result {
        .init(image:image,duplicate:duplicate,fixedLeading:edges?.0 ?? 0,fixedTrailing:edges?.1 ?? 0,viewportOffset:offset)
    }
    private func validate(_ edges:(Int,Int),height:Int) throws {
        guard edges.0 >= 0,edges.1 >= 0,edges.0 <= height-32,edges.1 <= height-32-edges.0 else {throw StitchFailure.fixedEdges}
    }
    private func crop(_ image:CGImage,leading:Int,trailing:Int) throws -> CGImage {
        if leading == 0,trailing == 0 {return image}
        guard let result=image.cropping(to:CGRect(x:0,y:leading,width:image.width,height:image.height-leading-trailing)) else {throw CaptureFailure.invalidImage}
        return result
    }
    private func detect(_ a:[UInt8],_ b:[UInt8],width:Int,height:Int) throws -> (Int,Int) {
        func equalRow(_ y:Int) -> Bool {
            var error=0,count=0
            for x in stride(from:0,to:width,by:max(1,width/128)) {for c in 0..<4 {
                let i=(y*width+x)*4+c;error+=abs(Int(a[i])-Int(b[i]));count+=1
            }}
            return Double(error)/Double(count) <= 0.5
        }
        let maximum=max(0,min(height/3,height-32))
        var leading=0,trailing=0
        while leading < maximum,equalRow(leading) {leading+=1}
        while trailing < maximum,equalRow(height-1-trailing) {trailing+=1}
        // An edge extending beyond the detection budget is not a known boundary.
        if leading == maximum,maximum > 0,equalRow(leading) {leading=0}
        if trailing == maximum,maximum > 0,equalRow(height-1-trailing) {trailing=0}
        try validate((leading,trailing),height:height)
        return (leading,trailing)
    }
    /// Row projections bound memory for a growing document. KMP finds candidates in linear time;
    /// full viewport pixels then prove each candidate, so projection/hash collisions cannot align data.
    private func contained(_ needle:CGImage,in image:CGImage) throws -> Int? {
        guard image.height >= needle.height else {return nil}
        func rows(_ source:CGImage) throws -> [UInt64] {
            let width=min(32,source.width),ctx=try CaptureStitcher.context(width:width,height:source.height)
            ctx.interpolationQuality = .none
            ctx.draw(source,in:CGRect(x:0,y:0,width:width,height:source.height))
            guard let bytes=ctx.data?.assumingMemoryBound(to:UInt8.self) else {throw CaptureFailure.invalidImage}
            return (0..<source.height).map {y in
                var hash:UInt64=14695981039346656037
                for i in y*width*4..<(y+1)*width*4 {hash=(hash ^ UInt64(bytes[i])) &* 1099511628211}
                return hash
            }
        }
        let pattern=try rows(needle),haystack=try rows(image),pixels=try CaptureStitcher.pixels(needle)
        var prefix=[Int](repeating:0,count:pattern.count),length=0
        for i in 1..<pattern.count {
            while length > 0,pattern[i] != pattern[length] {length=prefix[length-1]}
            if pattern[i] == pattern[length] {length+=1};prefix[i]=length
        }
        length=0
        var found:Int?,candidates=0
        for (i,row) in haystack.enumerated() {
            while length > 0,row != pattern[length] {length=prefix[length-1]}
            if row == pattern[length] {length+=1}
            if length == pattern.count {
                candidates+=1;guard candidates <= 128 else {throw StitchFailure.noOverlap}
                let start=i-pattern.count+1
                if let candidate=image.cropping(to:CGRect(x:0,y:start,width:needle.width,height:needle.height)),try CaptureStitcher.pixels(candidate) == pixels {
                    guard found == nil else {throw StitchFailure.noOverlap};found=start
                }
                length=prefix[length-1]
            }
        }
        return found
    }
    private func compose(_ body:CGImage,first:CGImage,last:CGImage,edges:(Int,Int)) throws -> CGImage {
        if edges.0 == 0,edges.1 == 0 {return body}
        let height=edges.0+body.height+edges.1,ctx=try CaptureStitcher.context(width:body.width,height:height)
        if edges.0 > 0,let header=first.cropping(to:CGRect(x:0,y:0,width:first.width,height:edges.0)) {
            ctx.draw(header,in:CGRect(x:0,y:height-edges.0,width:body.width,height:edges.0))
        }
        ctx.draw(body,in:CGRect(x:0,y:edges.1,width:body.width,height:body.height))
        if edges.1 > 0,let footer=last.cropping(to:CGRect(x:0,y:last.height-edges.1,width:last.width,height:edges.1)) {
            ctx.draw(footer,in:CGRect(x:0,y:0,width:body.width,height:edges.1))
        }
        guard let image=ctx.makeImage() else {throw CaptureFailure.invalidImage};return image
    }
}
