import Foundation
import Darwin

public enum CaptureScriptValue:Codable,Sendable,Equatable {
    case null,bool(Bool),number(Double),string(String),array([Self]),object([String:Self])
    public init(from decoder:Decoder) throws {
        let c=try decoder.singleValueContainer()
        if c.decodeNil(){self = .null} else if let v=try? c.decode(Bool.self){self = .bool(v)} else if let v=try? c.decode(Double.self){self = .number(v)} else if let v=try? c.decode(String.self){self = .string(v)} else if let v=try? c.decode([Self].self){self = .array(v)} else {self = .object(try c.decode([String:Self].self))}
    }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.singleValueContainer();switch self {case .null:try c.encodeNil();case .bool(let v):try c.encode(v);case .number(let v):try c.encode(v);case .string(let v):try c.encode(v);case .array(let v):try c.encode(v);case .object(let v):try c.encode(v)}
    }
}
public struct CaptureScriptMessage:Codable,Sendable {
    public var kind:String
    public var id:Int?
    public var action:String?
    public var source:String?
    public var text:String?
    public var value:CaptureScriptValue?
    private enum CodingKeys:String,CodingKey {case kind,id,action,source,text,value}
    public init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        kind=try c.decode(String.self,forKey:.kind);id=try c.decodeIfPresent(Int.self,forKey:.id)
        action=try c.decodeIfPresent(String.self,forKey:.action);source=try c.decodeIfPresent(String.self,forKey:.source);text=try c.decodeIfPresent(String.self,forKey:.text)
        // A present JSON null is a script result, distinct from an absent protocol field.
        value=c.contains(.value) ? try c.decode(CaptureScriptValue.self,forKey:.value) : nil
    }
    public init(_ kind:String,id:Int?=nil,action:String?=nil,source:String?=nil,text:String?=nil,value:CaptureScriptValue?=nil) {self.kind=kind;self.id=id;self.action=action;self.source=source;self.text=text;self.value=value}
}
public enum CaptureScriptFailure:LocalizedError,Equatable {
    case invalidSource,protocolError,workerStopped,unavailable,timedOut,memoryLimit,cancelled,execution(String)
    public var errorDescription:String? {switch self {
    case .invalidSource:return "Capture scripts must contain 1–16384 UTF-8 bytes."
    case .protocolError:return "The capture script worker returned an invalid response."
    case .workerStopped:return "The capture script worker stopped before returning a result."
    case .unavailable:return "The capture script worker is unavailable. Rebuild or reinstall Thermo."
    case .timedOut:return "The capture script exceeded its time limit. Completed actions are kept."
    case .memoryLimit:return "The capture script exceeded its memory limit. Completed actions are kept."
    case .cancelled:return "The capture script was cancelled. Completed actions are kept."
    case .execution(let text):return text
    }}
}
/// One escaped JSON frame per line. Reader owns the descriptor's reads, not its lifetime.
public final class CaptureScriptWire {
    private let descriptor:Int32
    private var buffer=Data()
    public init(descriptor:Int32){self.descriptor=descriptor}
    public func read() throws -> CaptureScriptMessage {
        while true {
            if let newline=buffer.firstIndex(of:10) {
                guard newline <= 65536 else {throw CaptureScriptFailure.protocolError}
                let frame=buffer.prefix(upTo:newline);buffer.removeSubrange(...newline)
                return try JSONDecoder().decode(CaptureScriptMessage.self,from:frame)
            }
            guard buffer.count <= 65536 else {throw CaptureScriptFailure.protocolError}
            var chunk=[UInt8](repeating:0,count:4096)
            let count=Darwin.read(descriptor,&chunk,chunk.count)
            if count < 0 && errno == EINTR {continue}
            if count == 0{throw CaptureScriptFailure.workerStopped};guard count > 0 else {throw CaptureScriptFailure.protocolError};buffer.append(contentsOf:chunk.prefix(count))
        }
    }
    public static func write(_ message:CaptureScriptMessage,to descriptor:Int32) throws {
        var data=try JSONEncoder().encode(message);guard data.count <= 65536 else {throw CaptureScriptFailure.protocolError};data.append(10)
        try data.withUnsafeBytes {bytes in
            var offset=0
            while offset < bytes.count {
                let count=Darwin.write(descriptor,bytes.baseAddress!.advanced(by:offset),bytes.count-offset)
                if count < 0 && errno == EINTR {continue};guard count > 0 else {throw CaptureScriptFailure.protocolError};offset += count
            }
        }
    }
}
