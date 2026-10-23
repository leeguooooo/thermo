import Foundation

public enum CaptureWordDocument {
    public static func data(formula:CaptureLaTeX) throws -> Data {
        let rendered=try formula.render(),math=try CaptureOfficeMath.convert(rendered.mathml,formula:formula)
        guard math.utf8.count <= 12*1024*1024 else { throw CaptureWordFailure.invalidMath }
        let resources=try templateDirectory()
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("thermo-word-"+UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer { try? FileManager.default.removeItem(at:temporary) }
        let folder=temporary.appendingPathComponent("document",isDirectory:true)
        try FileManager.default.copyItem(at:resources.appendingPathComponent("TemplateParts"),to:folder)
        let document=folder.appendingPathComponent("word/document.xml")
        var xml=try String(contentsOf:document,encoding:.utf8)
        let slot=try String(contentsOf:resources.appendingPathComponent("math-slot.xml"),encoding:.utf8)
        guard !slot.isEmpty,xml.components(separatedBy:slot).count == 2 else { throw CaptureWordFailure.missingTemplate }
        xml=xml.replacingOccurrences(of:slot,with:math)
        if !formula.transparentBackground {
            guard let body=xml.range(of:"<w:p>") else { throw CaptureWordFailure.missingTemplate }
            xml.insert(contentsOf:"<w:pPr><w:shd w:val=\"clear\" w:fill=\"\(formula.background.dropFirst())\"/></w:pPr>",at:body.upperBound)
        }
        try Data(xml.utf8).write(to:document,options:.atomic)
        let archive=temporary.appendingPathComponent("formula.docx"),process=Process(),errors=Pipe()
        process.executableURL=URL(fileURLWithPath:"/usr/bin/ditto");process.arguments=["-c","-k","--norsrc","--noextattr","--noacl",folder.path,archive.path]
        process.standardOutput=FileHandle.nullDevice;process.standardError=errors
        try process.run();process.waitUntilExit()
        guard process.terminationStatus == 0,let size=try archive.resourceValues(forKeys:[.fileSizeKey]).fileSize,size <= 16*1024*1024 else { throw CaptureWordFailure.packageFailed }
        return try Data(contentsOf:archive)
    }
    public static func save(_ formula:CaptureLaTeX,to url:URL) throws { try data(formula:formula).write(to:url,options:.atomic) }
    private static func templateDirectory() throws -> URL {
        var candidates:[URL]=[]
        if let resources=Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("CaptureWord",isDirectory:true)) }
        #if DEBUG
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(repo.appendingPathComponent("Resources/CaptureWord",isDirectory:true))
        #endif
        guard let value=candidates.first(where:{ FileManager.default.fileExists(atPath:$0.appendingPathComponent("math-slot.xml").path) }) else { throw CaptureWordFailure.missingTemplate };return value
    }
}
