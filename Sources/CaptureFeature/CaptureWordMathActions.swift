import AppKit
import CaptureCore
import UniformTypeIdentifiers

@MainActor enum CaptureWordMathActions {
    static var wordApplication:URL? { guard let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.microsoft.Word"),FileManager.default.fileExists(atPath:url.path) else { return nil };return url }
    static func export(_ formula:CaptureLaTeX) throws {
        let data=try CaptureWordDocument.data(formula:formula)
        let panel=NSSavePanel();panel.allowedContentTypes=[UTType(filenameExtension:"docx")!];panel.nameFieldStringValue="Thermo-formula.docx"
        guard panel.runModal() == .OK,let url=panel.url else { return }
        try data.write(to:url,options:.atomic)
    }
    static func openCopy(_ formula:CaptureLaTeX,onError:@escaping(String)->Void) throws {
        guard let application=wordApplication else { throw CaptureWordFailure.wordNotInstalled }
        let root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("Thermo/FormulaDocuments",isDirectory:true)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        // Every explicit open creates its own document; never replace a copy the user may have edited.
        let directory=root.appendingPathComponent(UUID().uuidString,isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
        let url=directory.appendingPathComponent("Thermo-formula.docx")
        do { try CaptureWordDocument.save(formula,to:url) } catch { try? FileManager.default.removeItem(at:directory);throw error }
        NSWorkspace.shared.open([url],withApplicationAt:application,configuration:NSWorkspace.OpenConfiguration()) { _,error in
            if let error { Task { @MainActor in onError(captureFailureMessage(error)) } }
        }
    }
}
