import Foundation

public struct CaptureCLIReport:Codable,Sendable {
    public enum Phase:String,Codable,Sendable {case idle,validated,running,succeeded,failed,cancelled,unknown}
    public var schema=1
    public var id:UUID?
    public var phase:Phase
    public var cancelRequested=false
    public var result:CaptureScriptResult?
    public var issue:String?
    public init(id:UUID?=nil,phase:Phase,result:CaptureScriptResult?=nil,issue:String?=nil) {self.id=id;self.phase=phase;self.result=result;self.issue=issue}
}
