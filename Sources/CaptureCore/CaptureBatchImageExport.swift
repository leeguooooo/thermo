import AppKit
import Darwin

public struct CaptureBatchImageItem:Sendable {
    public enum Source:@unchecked Sendable {case document(CaptureDocument),saved(root:URL,pin:CaptureSavedPin)}
    public let id:UUID
    public let groupID:UUID
    public let groupName:String
    public let title:String
    public let source:Source
    public init(id:UUID,groupID:UUID,groupName:String,title:String,source:Source) {
        self.id=id;self.groupID=groupID;self.groupName=groupName;self.title=title;self.source=source
    }
}
public struct CaptureBatchImageEntry:Codable,Sendable {
    public let id:UUID
    public let groupID:UUID
    public let groupName:String
    public let title:String
    public let file:String
    public let width:Int
    public let height:Int
}
public struct CaptureBatchImageManifest:Codable,Sendable {
    public let version:Int
    public let format:CaptureSaveFormat
    public let images:[CaptureBatchImageEntry]
}
public struct CaptureBatchImageResult:Sendable {
    public let folder:URL
    public let images:[CaptureBatchImageEntry]
}
public enum CaptureBatchExportFailure:LocalizedError {
    case noImages,invalidPlan
    public var errorDescription:String? {
        switch self {
        case .noImages:return "No open image pins in the selected scope."
        case .invalidPlan:return "The batch image export plan is invalid."
        }
    }
}
public enum CaptureBatchImageExport {
    private static func posix() -> Error {NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    private static func safeTitle(_ value:String) -> String {
        var output=""
        for character in value {
            let next=character.unicodeScalars.allSatisfy{CharacterSet.alphanumerics.contains($0) || "-_ ".unicodeScalars.contains($0)} ? String(character) : "_"
            if output.utf8.count+next.utf8.count>100 {break};output += next
        }
        return output.trimmingCharacters(in:.whitespaces)
    }
    public static func run(_ items:[CaptureBatchImageItem],in destination:URL,format:CaptureSaveFormat,quality:Double=0.9,
                           checkCancellation:()throws->Void={try Task.checkCancellation()},
                           progress:(Int,Int)->Void={_,_ in},
                           encode:(CaptureDocument,CaptureSaveFormat,Double)throws->Data={try CaptureImageSave.encode($0,format:$1,quality:$2)}) throws -> CaptureBatchImageResult {
        guard !items.isEmpty else {throw CaptureBatchExportFailure.noImages}
        guard items.count<=1000,Set(items.map(\.id)).count==items.count,destination.isFileURL,!destination.path.contains("\0"),quality.isFinite,(0...1).contains(quality),items.allSatisfy({$0.title.count<=2000 && $0.groupName.count<=100}) else {throw CaptureBatchExportFailure.invalidPlan}
        try checkCancellation()
        let scope=destination.startAccessingSecurityScopedResource();defer{if scope {destination.stopAccessingSecurityScopedResource()}}
        let parent=open(destination.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parent>=0 else{throw posix()};defer{close(parent)}
        let token=UUID().uuidString.lowercased(),stage=".thermo-batch-"+token,final="Thermo-pins-"+token
        guard mkdirat(parent,stage,0o700)==0 else{throw posix()}
        let folder=openat(parent,stage,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard folder>=0 else{_ = unlinkat(parent,stage,AT_REMOVEDIR);throw posix()}
        var files:[String]=[],published=false
        defer {
            if !published {for file in files {_ = unlinkat(folder,file,0)};_ = unlinkat(parent,stage,AT_REMOVEDIR)}
            close(folder)
        }
        func write(_ bytes:Data,name:String) throws {
            let fd=openat(folder,name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
            guard fd>=0 else{throw posix()};files.append(name);defer{close(fd)}
            try bytes.withUnsafeBytes {buffer in
                var offset=0
                while offset<buffer.count {
                    let count=Darwin.write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                    if count<0,errno==EINTR {continue}
                    guard count>0 else{throw posix()};offset += count
                }
            }
            guard fsync(fd)==0 else{throw posix()}
        }
        var entries:[CaptureBatchImageEntry]=[]
        for (index,item) in items.enumerated() {
            try checkCancellation()
            let document:CaptureDocument
            switch item.source {
            case .document(let value):document=value
            case .saved(let root,let pin):
                guard pin.contentKind==nil else{throw CaptureBatchExportFailure.invalidPlan}
                document=try CapturePinLibraryStore(root:root).document(for:pin)
            }
            guard document.image.height>0,document.image.width<=80000000/document.image.height else {throw CaptureBatchExportFailure.invalidPlan}
            let name=String(format:"%04d",index+1)+"-"+safeTitle(item.title)+"-"+String(item.id.uuidString.prefix(8)).lowercased()+"."+format.fileExtension
            let bytes=try encode(document,format,quality)
            try checkCancellation();try write(bytes,name:name)
            entries.append(.init(id:item.id,groupID:item.groupID,groupName:item.groupName,title:item.title,file:name,width:document.image.width,height:document.image.height))
            progress(index+1,items.count)
        }
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        let manifest=try encoder.encode(CaptureBatchImageManifest(version:1,format:format,images:entries))
        guard manifest.count<=16*1024*1024 else{throw CaptureBatchExportFailure.invalidPlan}
        try write(manifest,name:"manifest.json");try checkCancellation()
        guard renameatx_np(parent,stage,parent,final,UInt32(RENAME_EXCL))==0 else{throw posix()}
        published=true
        return .init(folder:destination.appendingPathComponent(final,isDirectory:true),images:entries)
    }
}
