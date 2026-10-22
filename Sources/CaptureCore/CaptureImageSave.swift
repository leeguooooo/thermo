import AppKit
import Darwin

public enum CaptureImageSave {
    public static func encode(_ document:CaptureDocument,format:CaptureSaveFormat,quality:Double) throws -> Data {
        guard quality.isFinite,(0...1).contains(quality) else { throw CaptureSaveFailure.invalidSettings }
        let image=try document.rendered()
        // JPEG has no alpha; flatten on white rather than exposing undefined transparent RGB.
        let output:CGImage
        if format == .jpeg {
            guard let ctx=CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:0,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CaptureFailure.exportFailed }
            ctx.setFillColor(NSColor.white.cgColor);ctx.fill(CGRect(x:0,y:0,width:image.width,height:image.height));ctx.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
            guard let flattened=ctx.makeImage() else { throw CaptureFailure.exportFailed };output=flattened
        } else { output=image }
        guard let data=NSBitmapImageRep(cgImage:output).representation(using:format.bitmapType,properties:format == .jpeg ? [.compressionFactor:quality] : [:]) else { throw CaptureFailure.exportFailed };return data
    }
    public static func save(_ document:CaptureDocument,to destination:CaptureSaveDestination,quality:Double,date:Date=Date(),uuid:UUID=UUID()) throws -> URL {
        guard destination.valid else { throw CaptureSaveFailure.invalidSettings }
        guard !destination.directory.isEmpty else { throw CaptureSaveFailure.missingDirectory }
        var directory=URL(fileURLWithPath:destination.directory,isDirectory:true)
        if let bookmark=destination.bookmark {
            var stale=false;directory=try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],bookmarkDataIsStale:&stale)
            guard !stale else { throw CaptureSaveFailure.staleBookmark }
        }
        guard directory.isFileURL else {throw CaptureSaveFailure.missingDirectory}
        let scope=directory.startAccessingSecurityScopedResource();defer { if scope { directory.stopAccessingSecurityScopedResource() } }
        let relative=try CaptureSaveNaming.relativePath(template:destination.template,width:document.image.width,height:document.image.height,format:destination.format,date:date,uuid:uuid)
        let data=try encode(document,format:destination.format,quality:quality)
        return try publish(data,in:directory,relative:relative)
    }
    private static func posix() -> Error { NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
    private static func publish(_ data:Data,in directory:URL,relative:String) throws -> URL {
        // Walk beneath the chosen folder using directory descriptors: symlink subfolders cannot redirect a save.
        var parent=open(directory.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard parent >= 0 else { throw posix() };defer { close(parent) }
        let parts=relative.split(separator:"/").map(String.init)
        for part in parts.dropLast() {
            if mkdirat(parent,part,0o700) != 0 && errno != EEXIST { throw posix() }
            let next=openat(parent,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard next >= 0 else { throw posix() };close(parent);parent=next
        }
        let temporary=".thermo-save-"+UUID().uuidString
        let file=openat(parent,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard file >= 0 else { throw posix() };defer { close(file);unlinkat(parent,temporary,0) }
        try data.withUnsafeBytes { buffer in
            var offset=0
            while offset < buffer.count {
                let count=Darwin.write(file,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                if count < 0 { if errno == EINTR { continue };throw posix() };guard count > 0 else { throw CaptureFailure.exportFailed };offset += count
            }
        }
        guard fsync(file) == 0 else { throw posix() }
        let name=parts.last!,stem=(name as NSString).deletingPathExtension,ext=(name as NSString).pathExtension
        for number in 1...10000 {
            let candidate=number == 1 ? name : "\(stem)-\(number).\(ext)"
            if linkat(parent,temporary,parent,candidate,0) == 0 {
                var result=directory;for part in parts.dropLast() { result.appendPathComponent(part,isDirectory:true) };return result.appendingPathComponent(candidate)
            }
            guard errno == EEXIST else { throw posix() }
        }
        throw CaptureFailure.exportFailed
    }
}
