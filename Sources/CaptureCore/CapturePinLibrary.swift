import AppKit
import Foundation
import ImageIO
import Darwin

public struct CapturePinGroup:Codable,Identifiable,Sendable {
    public var id:UUID
    public var name:String
    public var color:String?
    public init(name:String,color:String? = nil) { id=UUID();self.name=name;self.color=color }
}
public struct CaptureSavedPin:Codable,Identifiable,Sendable {
    public var id=UUID()
    public var groupID:UUID
    public var snapshotID=UUID()
    public var title=""
    public var contentKind:String?
    public var closedAt:Date?
    public var hidden=false
    public var frame=CGRect.zero
    public var opacity=1.0
    public var zoom=1.0
    public var pan=CGPoint.zero
    public var pinned=true
    public var locked=false
    public var shadow=true
    public init(groupID:UUID) { self.groupID=groupID }
    var valid:Bool {
        (contentKind.map { ["text","files","color"].contains($0) } ?? true) && (closedAt?.timeIntervalSince1970.isFinite ?? true) && title.count <= 2000 && [frame.minX,frame.minY,frame.width,frame.height,pan.x,pan.y].allSatisfy(\.isFinite) && frame.width >= 0 && frame.height >= 0 &&
        opacity.isFinite && (0.15...1).contains(opacity) && zoom.isFinite && (0.25...4).contains(zoom)
    }
}
public struct CapturePinLibrary:Codable,Sendable {
    public var version=1
    public var revision=UUID()
    public var groups:[CapturePinGroup]
    public var currentGroupID:UUID
    public var pins:[CaptureSavedPin]=[]
    public var historyLimit=10
    public init(defaultName:String="Default") { let group=CapturePinGroup(name:defaultName);groups=[group];currentGroupID=group.id }
    public var valid:Bool {
        version == 1 && !groups.isEmpty && groups.count <= 100 && Set(groups.map(\.id)).count == groups.count &&
        Set(groups.map { $0.name.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() }).count == groups.count &&
        groups.allSatisfy { !$0.name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && $0.name.count <= 100 && ($0.color == nil || Self.validColor($0.color!)) } &&
        groups.contains { $0.id == currentGroupID } && pins.count <= 1000 && Set(pins.map(\.id)).count == pins.count &&
        pins.allSatisfy { pin in pin.valid && groups.contains { $0.id == pin.groupID } } && (0...100).contains(historyLimit)
    }
    public static func validColor(_ value:String) -> Bool { value.count == 7 && value.first == "#" && value.dropFirst().allSatisfy { $0.isHexDigit && $0.isASCII } }
    public mutating func pruneHistory() {
        for group in groups {
            let closed=pins.filter { $0.groupID == group.id && $0.closedAt != nil }.sorted { $0.closedAt! > $1.closedAt! }
            let removed=Set(closed.dropFirst(historyLimit).map(\.id));pins.removeAll { removed.contains($0.id) }
        }
    }
}
public enum CapturePinFailure:LocalizedError {
    case invalidLibrary,missingPin,invalidName,invalidContent,missingSourceFile
    public var errorDescription:String? {
        switch self {
        case .invalidContent:return "The pin content is unsupported or exceeds its size limit."
        case .missingSourceFile:return "The source file no longer exists."
        case .invalidLibrary:return "The saved pin library is invalid or could not be read."
        case .missingPin:return "The saved pin could not be found."
        case .invalidName:return "Use a unique group name of 1 to 100 characters."
        }
    }
}

/// Snapshot directories are immutable. The atomic manifest is the only commit point.
/// Failed saves keep the previous manifest and all its referenced snapshots intact.
public struct CapturePinSnapshot {
    public let document:CaptureDocument
    public let content:CapturePinContent?
}

public final class CapturePinLibraryStore {
    public let root:URL
    private var expectedRevision:UUID?
    public init(root:URL? = nil) {
        self.root=root ?? FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Thermo/Pins",isDirectory:true)
    }
    private var snapshots:URL { root.appendingPathComponent("snapshots",isDirectory:true) }
    private var manifest:URL { root.appendingPathComponent("library.json") }
    private func directory(_ url:URL) throws {
        let v=try url.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard v.isDirectory == true,v.isSymbolicLink != true else { throw CapturePinFailure.invalidLibrary }
    }
    private func checkRegular(_ url:URL,limit:Int) throws {
        let v=try url.resourceValues(forKeys:[.isRegularFileKey,.isSymbolicLinkKey,.fileSizeKey])
        guard v.isRegularFile == true,v.isSymbolicLink != true,(v.fileSize ?? Int.max) <= limit else { throw CapturePinFailure.invalidLibrary }
    }
    private func regular(_ url:URL,limit:Int) throws -> Data { try checkRegular(url,limit:limit);return try Data(contentsOf:url) }
    private func prepare() throws {
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700]);try directory(root)
        if !FileManager.default.fileExists(atPath:snapshots.path) { try FileManager.default.createDirectory(at:snapshots,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]) };try directory(snapshots)
    }
    public func load(defaultName:String="Default") throws -> CapturePinLibrary {
        guard FileManager.default.fileExists(atPath:root.path) else { expectedRevision=nil;return .init(defaultName:defaultName) }
        try directory(root)
        guard FileManager.default.fileExists(atPath:manifest.path) else {
            // A first failed save may leave only an empty snapshots directory.
            let files=try FileManager.default.contentsOfDirectory(atPath:root.path)
            guard files.allSatisfy({ ["snapshots",".lock"].contains($0) }) else { throw CapturePinFailure.invalidLibrary }
            expectedRevision=nil;return .init(defaultName:defaultName)
        }
        let value=try JSONDecoder().decode(CapturePinLibrary.self,from:regular(manifest,limit:4*1024*1024))
        guard value.valid else { throw CapturePinFailure.invalidLibrary };expectedRevision=value.revision;return value
    }
    public func document(for pin:CaptureSavedPin) throws -> CaptureDocument { try snapshot(for:pin).document }
    public func snapshot(for pin:CaptureSavedPin) throws -> CapturePinSnapshot {
        try directory(root);try directory(snapshots)
        let folder=snapshots.appendingPathComponent(pin.snapshotID.uuidString,isDirectory:true);try directory(folder)
        let annotations=try JSONDecoder().decode([CaptureVectorAnnotation].self,from:regular(folder.appendingPathComponent("annotations.json"),limit:4*1024*1024))
        guard annotations.count <= 1000,annotations.allSatisfy(\.valid) else { throw CapturePinFailure.invalidLibrary }
        let data=try regular(folder.appendingPathComponent("image.png"),limit:128*1024*1024)
        guard let source=CGImageSourceCreateWithData(data as CFData,nil),let props=CGImageSourceCopyPropertiesAtIndex(source,0,nil) as? [CFString:Any],
              let width=props[kCGImagePropertyPixelWidth] as? Int,let height=props[kCGImagePropertyPixelHeight] as? Int,
              width > 0,height > 0,width <= 80000000/height,let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CapturePinFailure.invalidLibrary }
        let contentURL=folder.appendingPathComponent("content.json")
        var content:CapturePinContent?
        if pin.contentKind != nil || FileManager.default.fileExists(atPath:contentURL.path) || (try? contentURL.resourceValues(forKeys:[.isSymbolicLinkKey]).isSymbolicLink) == true {
            content=try JSONDecoder().decode(CapturePinContent.self,from:regular(contentURL,limit:12*1024*1024))
            guard content?.valid == true,content?.kind == pin.contentKind else { throw CapturePinFailure.invalidLibrary }
            if case .text(let text)=content,text.rtf != nil { _=try text.attributed() }
        }
        return CapturePinSnapshot(document:CaptureDocument(image:image,annotations:annotations.compactMap(\.annotation)),content:content)
    }
    @discardableResult public func save(_ library:CapturePinLibrary,documents:[UUID:CaptureDocument]=[:],contents:[UUID:CapturePinContent]=[:]) throws -> CapturePinLibrary {
        guard library.valid,documents.keys.allSatisfy({ id in library.pins.contains { $0.id == id } }) else { throw CapturePinFailure.invalidLibrary }
        guard contents.allSatisfy({ documents[$0.key] != nil && $0.value.valid }),library.pins.filter({ documents[$0.id] != nil }).allSatisfy({ contents[$0.id]?.kind == $0.contentKind }) else { throw CapturePinFailure.invalidLibrary }
        try prepare()
        let fd=Darwin.open(root.appendingPathComponent(".lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        guard fd >= 0 else { throw CapturePinFailure.invalidLibrary }
        defer { _=flock(fd,LOCK_UN);_ = Darwin.close(fd) }
        guard flock(fd,LOCK_EX|LOCK_NB) == 0 else { throw CapturePinFailure.invalidLibrary }
        if FileManager.default.fileExists(atPath:manifest.path) {
            let current=try JSONDecoder().decode(CapturePinLibrary.self,from:regular(manifest,limit:4*1024*1024))
            guard current.valid,current.revision == expectedRevision else { throw CapturePinFailure.invalidLibrary }
        } else if expectedRevision != nil { throw CapturePinFailure.invalidLibrary }
        var committed=library;committed.revision=UUID()
        var created:[URL]=[]
        do {
            for (id,doc) in documents {
                let pin=library.pins.first { $0.id == id }!
                let folder=snapshots.appendingPathComponent(pin.snapshotID.uuidString,isDirectory:true)
                guard !FileManager.default.fileExists(atPath:folder.path),doc.image.height > 0,doc.image.width <= 80000000/doc.image.height else { throw CapturePinFailure.invalidLibrary }
                let vector=doc.annotations.map { CaptureVectorAnnotation($0,start:0,end:1) }
                guard vector.count <= 1000,vector.allSatisfy(\.valid),let png=NSBitmapImageRep(cgImage:doc.image).representation(using:.png,properties:[:]),png.count <= 128*1024*1024 else { throw CapturePinFailure.invalidLibrary }
                let metadata=try JSONEncoder().encode(vector);guard metadata.count <= 4*1024*1024 else { throw CapturePinFailure.invalidLibrary }
                try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);created.append(folder)
                try png.write(to:folder.appendingPathComponent("image.png"),options:.atomic)
                try metadata.write(to:folder.appendingPathComponent("annotations.json"),options:.atomic)
                if let content=contents[id] {
                    let data=try JSONEncoder().encode(content);guard data.count <= 12*1024*1024 else { throw CapturePinFailure.invalidLibrary }
                    try data.write(to:folder.appendingPathComponent("content.json"),options:.atomic)
                }
            }
            // Do not commit a reference to an absent or symlinked snapshot.
            for pin in library.pins {
                let folder=snapshots.appendingPathComponent(pin.snapshotID.uuidString);try directory(folder)
                try checkRegular(folder.appendingPathComponent("image.png"),limit:128*1024*1024)
                try checkRegular(folder.appendingPathComponent("annotations.json"),limit:4*1024*1024)
            }
            let data=try JSONEncoder().encode(committed);guard data.count <= 4*1024*1024 else { throw CapturePinFailure.invalidLibrary }
            try data.write(to:manifest,options:.atomic);expectedRevision=committed.revision
        } catch { for url in created { try? FileManager.default.removeItem(at:url) };throw error }
        // Only UUID snapshot folders owned by this store are eligible for collection.
        let live=Set(library.pins.map { $0.snapshotID.uuidString })
        for url in (try? FileManager.default.contentsOfDirectory(at:snapshots,includingPropertiesForKeys:nil)) ?? [] where UUID(uuidString:url.lastPathComponent) != nil && !live.contains(url.lastPathComponent) {
            try? FileManager.default.removeItem(at:url)
        }
        return committed
    }
}
