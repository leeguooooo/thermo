import Foundation
import CoreGraphics

public struct CaptureTextSegment:Sendable,Equatable {
    public let range:NSRange
    /// Vision coordinates: normalized, with origin at bottom left.
    public let bounds:CGRect
    public init(range:NSRange,bounds:CGRect) {self.range=range;self.bounds=bounds}
}

public enum CaptureTextSelection {
    public static func text(in source:String,segments:[CaptureTextSegment],selected:Set<Int>) -> String {
        let count=source.utf16.count
        let ranges=selected.sorted().compactMap {index -> NSRange? in
            guard segments.indices.contains(index) else {return nil}
            let range=segments[index].range
            guard range.location >= 0,range.length > 0,range.location <= count,range.length <= count-range.location,Range(range,in:source) != nil else {return nil}
            return range
        }.sorted{$0.location < $1.location}
        var merged:[NSRange]=[]
        for range in ranges {
            if let last=merged.last,range.location <= NSMaxRange(last) {
                merged[merged.count-1]=NSRange(location:last.location,length:max(NSMaxRange(last),NSMaxRange(range))-last.location)
            } else {merged.append(range)}
        }
        let string=source as NSString
        var output="",end:Int?
        for range in merged {
            if let end {
                let gap=string.substring(with:NSRange(location:end,length:range.location-end))
                output += gap.allSatisfy(\.isWhitespace) ? gap : (gap.contains("\n") ? "\n" : " ")
            }
            output += string.substring(with:range);end=NSMaxRange(range)
        }
        return output
    }
}
