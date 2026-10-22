import AppKit

public enum StitchFailure: LocalizedError {
    case dimensions, noOverlap, tooLarge, blankOverlap
    public var errorDescription: String? {
        switch self {
        case .dimensions: return "Frames must have the same width for vertical stitching or the same height for horizontal stitching."
        case .noOverlap: return "No reliable overlap found. Use frames with more shared static content."
        case .tooLarge: return "The stitched image exceeds the 80 megapixel memory limit."
        case .blankOverlap: return "The shared area is too uniform to align reliably."
        }
    }
}

/// Static-content matching. Never silently concatenates when alignment is uncertain.
public enum CaptureStitcher {
    public enum Direction { case vertical, horizontal }
    public struct Result { public let image: CGImage; public let overlap: Int; public let duplicate: Bool }
    private static let maxPixels = 80_000_000
    public static func append(_ next: CGImage, to previous: CGImage, direction: Direction = .vertical) throws -> Result {
        if direction == .horizontal {
            let a = try transposed(previous), b = try transposed(next)
            let result = try append(b, to: a)
            return Result(image: try transposed(result.image), overlap: result.overlap, duplicate: result.duplicate)
        }
        guard previous.width == next.width, previous.height >= 32, next.height >= 32 else { throw StitchFailure.dimensions }
        let width = previous.width, limit = min(previous.height, next.height)
        guard width <= maxPixels/previous.height, width <= maxPixels/next.height else { throw StitchFailure.tooLarge }
        guard let tail = previous.cropping(to: CGRect(x: 0, y: previous.height-limit, width: width, height: limit)) else { throw CaptureFailure.invalidImage }
        let a = try pixels(tail), b = try pixels(next)
        func score(_ overlap: Int) -> (Double, Double) {
            var error = 0.0, sum = 0.0, sumSquares = 0.0, count = 0.0
            for y in stride(from: 0, to: overlap, by: max(1, overlap/32)) {
                for x in stride(from: 0, to: width, by: max(1, width/32)) {
                    let ai = ((limit-overlap+y)*width+x)*4, bi = (y*width+x)*4
                    var luminance = 0.0
                    for channel in 0..<3 {
                        let av = Double(a[ai+channel]), bv = Double(b[bi+channel])
                        error += abs(av-bv); luminance += bv/3
                    }
                    sum += luminance; sumSquares += luminance*luminance; count += 1
                }
            }
            return (error/(count*3), sumSquares/count-pow(sum/count,2))
        }
        if next.height <= previous.height {
            let (error, variance) = score(limit)
            if error < 0.5 {
                guard variance > 20 else { throw StitchFailure.blankOverlap }
                return Result(image: previous, overlap: limit, duplicate: true)
            }
        }
        var best: (length: Int, error: Double, variance: Double)?
        var candidates: [(Int, Double)] = []
        for overlap in 16..<limit {
            let value = score(overlap)
            candidates.append((overlap, value.0))
            if best == nil || value.0 < best!.error { best = (overlap,value.0,value.1) }
        }
        guard let best, best.error < 6 else { throw StitchFailure.noOverlap }
        guard best.variance > 20 else { throw StitchFailure.blankOverlap }
        guard !candidates.contains(where: { abs($0.0-best.length) > 2 && $0.1 <= best.error+0.5 }) else { throw StitchFailure.noOverlap }
        let height = previous.height+next.height-best.length
        guard width <= maxPixels/height else { throw StitchFailure.tooLarge }
        let ctx = try context(width: width, height: height)
        ctx.draw(previous, in: CGRect(x: 0, y: height-previous.height, width: width, height: previous.height))
        // Keep the original overlap; append only newly revealed pixels.
        guard let tail = next.cropping(to: CGRect(x: 0,y: best.length,width: width,height: next.height-best.length)) else { throw CaptureFailure.invalidImage }
        ctx.draw(tail, in: CGRect(x: 0,y: 0,width: width,height: next.height-best.length))
        guard let image = ctx.makeImage() else { throw CaptureFailure.invalidImage }
        return Result(image: image, overlap: best.length, duplicate: false)
    }
    private static func context(width: Int, height: Int) throws -> CGContext {
        guard width > 0, height > 0, width <= maxPixels/height else { throw StitchFailure.tooLarge }
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw CaptureFailure.invalidImage }
        return ctx
    }
    private static func pixels(_ image: CGImage) throws -> [UInt8] {
        let ctx = try context(width: image.width, height: image.height)
        ctx.draw(image, in: CGRect(x: 0,y: 0,width: image.width,height: image.height))
        guard let data = ctx.data else { throw CaptureFailure.invalidImage }
        return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: image.width*image.height*4))
    }
    private static func transposed(_ image: CGImage) throws -> CGImage {
        let source = try pixels(image), width = image.height, height = image.width
        var output = [UInt8](repeating: 0, count: source.count)
        for y in 0..<image.height { for x in 0..<image.width {
            let from = (y*image.width+x)*4, to = (x*width+y)*4
            for channel in 0..<4 { output[to+channel] = source[from+channel] }
        } }
        guard let provider = CGDataProvider(data: Data(output) as CFData), let result = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width*4,
             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw CaptureFailure.invalidImage }
        return result
    }
}
