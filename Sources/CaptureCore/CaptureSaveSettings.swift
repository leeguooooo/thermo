import AppKit

public enum CaptureSaveFormat:String,Codable,CaseIterable,Sendable {
    case png,jpeg,tiff
    public var fileExtension:String { self == .jpeg ? "jpg" : rawValue }
    public var bitmapType:NSBitmapImageRep.FileType { switch self { case .png:return .png;case .jpeg:return .jpeg;case .tiff:return .tiff } }
}
public enum CaptureAfterStep:String,Codable,CaseIterable,Sendable,Identifiable {
    case copyImage,copyText,quickSave,pin
    public var id:String { rawValue }
    public var title:String { switch self { case .copyImage:return "Copy captured image";case .copyText:return "Copy captured OCR text";case .quickSave:return "Quick save captured image";case .pin:return "Open captured image as pin" } }
}
public struct CaptureSaveDestination:Codable,Equatable,Sendable {
    public var directory:String
    public var bookmark:Data?
    public var template:String
    public var format:CaptureSaveFormat
    public init(directory:String="",bookmark:Data?=nil,template:String="Thermo-$yyyy-MM-dd_HH-mm-ss-SSS$-%width%x%height%",format:CaptureSaveFormat = .png) {
        self.directory=directory;self.bookmark=bookmark;self.template=template;self.format=format
    }
    public var valid:Bool { directory.utf8.count <= 4096 && (directory.isEmpty || directory.hasPrefix("/")) && !directory.contains("\0") && (bookmark?.count ?? 0) <= 16384 && (try? CaptureSaveNaming.relativePath(template:template,width:1,height:1,format:format)) != nil }
}
public struct CaptureSaveSettings:Codable,Equatable,Sendable {
    public var version=1
    public var quick=CaptureSaveDestination()
    public var automatic=CaptureSaveDestination()
    public var autoSave=false
    public var quality:Double=0.9
    public var after:[CaptureAfterStep]=[.pin]
    public var copyAfterManualSave=false
    public init() {}
    public var valid:Bool { version == 1 && quick.valid && automatic.valid && quality.isFinite && (0...1).contains(quality) && after.count <= 4 && Set(after).count == after.count && (!autoSave || !automatic.directory.isEmpty) && (!after.contains(.quickSave) || !quick.directory.isEmpty) }
    public func data() throws -> Data {
        guard valid else { throw CaptureSaveFailure.invalidSettings };let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let data=try encoder.encode(self);guard data.count <= 65536 else { throw CaptureSaveFailure.invalidSettings };return data
    }
    public static func decode(_ data:Data) throws -> Self {
        guard data.count <= 65536 else { throw CaptureSaveFailure.invalidSettings };let value=try JSONDecoder().decode(Self.self,from:data)
        guard value.valid else { throw CaptureSaveFailure.invalidSettings };return value
    }
}
public enum CaptureSaveFailure:LocalizedError {
    case invalidSettings,invalidTemplate,missingDirectory,staleBookmark,noText,busy
    public var errorDescription:String? { switch self {
    case .invalidSettings:return "Capture save settings are invalid."
    case .invalidTemplate:return "Use a relative image name with supported variables; absolute paths and parent folders are not allowed."
    case .missingDirectory:return "Choose an existing folder before saving automatically."
    case .staleBookmark:return "The saved folder access has changed. Choose the folder again."
    case .noText:return "No text or barcode found."
    case .busy:return "A capture action chain is already running."
    } }
}
public enum CaptureSaveNaming {
    /// Templates are relative to a selected folder. No environment expansion or source-window lookup.
    public static func relativePath(template:String,width:Int,height:Int,format:CaptureSaveFormat,date:Date=Date(),uuid:UUID=UUID(),timeZone:TimeZone = .current) throws -> String {
        guard !template.isEmpty,template.utf8.count <= 1024,width>0,height>0 else { throw CaptureSaveFailure.invalidTemplate }
        var value=template
        let tokens=["yyyy","MM","dd","HH","mm","ss","SSS","yyyy-MM-dd","yyyy-MM-dd_HH-mm-ss","yyyy-MM-dd_HH-mm-ss-SSS"]
        for token in tokens.sorted(by:{$0.count > $1.count}) {
            let formatter=DateFormatter();formatter.locale=Locale(identifier:"en_US_POSIX");formatter.calendar=Calendar(identifier:.gregorian);formatter.timeZone=timeZone;formatter.dateFormat=token
            value=value.replacingOccurrences(of:"$"+token+"$",with:formatter.string(from:date))
        }
        for (token,replacement) in [("width",String(width)),("height",String(height)),("uuid",uuid.uuidString.lowercased()),("os","Mac")] {
            value=value.replacingOccurrences(of:"%"+token+"%",with:replacement)
        }
        guard !value.contains("$"),!value.contains("%"),!value.contains("\\"),!value.hasPrefix("/"),!value.unicodeScalars.contains(where:{CharacterSet.controlCharacters.contains($0)}) else { throw CaptureSaveFailure.invalidTemplate }
        let parts=value.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count <= 8,parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasPrefix(".") && !$0.contains(":") && $0.utf8.count <= 200 }) else { throw CaptureSaveFailure.invalidTemplate }
        // The format controls the extension. A typed known extension is replaced, never doubled.
        let ext=(value as NSString).pathExtension.lowercased()
        if ["png","jpg","jpeg","tif","tiff"].contains(ext) { value=(value as NSString).deletingPathExtension }
        return value+"."+format.fileExtension
    }
}
