import AppKit
import CaptureCore
import CaptureScriptCore

extension CaptureWorkspace {
    func executeScript(_ source:String,timeout:TimeInterval=300) async throws -> CaptureScriptResult {
        guard !scriptRunning else{throw CaptureSaveFailure.busy};scriptRunning=true;defer{scriptRunning=false}
        let worker=scriptWorker ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/thermo-capture-script")
        guard FileManager.default.isExecutableFile(atPath:worker.path) else {throw CaptureScriptFailure.unavailable}
        do {
            let result=try await CaptureScriptRunner.run(source:source,worker:worker,timeout:timeout) { [weak self] action in
                guard let self else {throw CaptureScriptFailure.unavailable};return try await self.performScriptAction(action)
            }
            try pinSession.flush();return result
        } catch {try? pinSession.flush();throw error}
    }
    func performScriptAction(_ raw:String) async throws -> CaptureScriptValue {
        try Task.checkCancellation()
        if raw == "status" {return .object(["pins":.number(Double(pinSession.count)),"capturing":.bool(capturing),"group":.string(pinSession.library.currentGroupID.uuidString)])}
        guard let action=CaptureAction(rawValue:raw) else {throw CaptureScriptFailure.execution("Unknown capture action: "+raw)}
        switch action {
        case .script,.scrolling,.recording,.recordingDrafts,.openImage,.saveImage:
            throw CaptureScriptFailure.execution("This action does not yet have a synchronous script API: "+raw)
        case .screenshot:return .bool(try await captureAndWait())
        case .screenshotCopy:return .bool(try await captureAndWait(after:[.copyImage]))
        case .screenshotOCR:return .bool(try await captureAndWait(after:[.copyText]))
        case .screenshotQuickSave:return .bool(try await captureAndWait(after:[.quickSave]))
        case .pinClipboard,.pinText,.pinLaTeX:
            switch try CapturePinClipboard.read(scriptPasteboard ?? .general,asText:action == .pinText,asLaTeX:action == .pinLaTeX) {
            case .image(let image):try pinSession.open(image)
            case .content(let content):try pinSession.open(content)
            };return .bool(true)
        case .recognize:
            guard let editor=pinSession.activeEditor(),editor.model.pinContent == nil else {throw CaptureActionFailure.imageRequired}
            return .string(try await editor.model.recognizeForScript())
        case .copyImage,.copyContent:
            guard let editor=pinSession.activeEditor() else {throw CaptureActionFailure.noPin}
            let board=scriptPasteboard ?? .general
            if action == .copyContent,let content=editor.model.pinContent {try CapturePinClipboard.copy(content,to:board)}
            else {
                guard editor.model.pinContent == nil else {throw CaptureActionFailure.imageRequired}
                let data=try editor.model.document.data();board.clearContents();guard board.setData(data,forType:.png) else {throw CaptureFailure.exportFailed}
            };return .bool(true)
        case .closePins:
            try perform(action);return .bool(pinSession.count == 0)
        case .closePin:
            guard let editor=pinSession.activeEditor() else {throw CaptureActionFailure.noPin};try perform(action)
            return .bool(!pinSession.windows.values.contains{ $0 === editor })
        default:try perform(action);return .bool(true)
        }
    }
}
