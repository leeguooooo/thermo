import AppKit
import CaptureCore
import ThermoL10n

@MainActor final class CaptureSaveModel:ObservableObject {
    static let preferenceKey="dev.thermo.capture.save.v1"
    @Published private(set) var settings=CaptureSaveSettings()
    @Published private(set) var invalidStoredSettings=false
    @Published private(set) var running=false
    @Published var issue:String?
    @Published private(set) var saved:[URL]=[]
    @Published private(set) var completed:[String]=[]
    private let write:(Data)throws->Void
    init(read:()->Data?={UserDefaults.standard.data(forKey:preferenceKey)},write:@escaping(Data)throws->Void={UserDefaults.standard.set($0,forKey:preferenceKey)}) {
        self.write=write
        if let data=read() { do { settings=try .decode(data) } catch { invalidStoredSettings=true;issue=captureFailureMessage(error) } }
    }
    @discardableResult func apply(_ value:CaptureSaveSettings) -> Bool {
        do { try write(value.data());settings=value;invalidStoredSettings=false;issue=nil;return true }
        catch { issue=captureFailureMessage(error);return false }
    }
    func snapshot() throws -> CaptureSaveSettings { guard !invalidStoredSettings else { throw CaptureSaveFailure.invalidSettings };return settings }
    /// The same immutable pixels and settings snapshot are used for every ordered step.
    func run(_ image:CGImage,settings value:CaptureSaveSettings,pin:(CGImage)throws->Void,copyImage:(Data)throws->Void,copyText:(String)throws->Void,
             recognize:(CGImage)async throws->String={image in try await Task.detached(priority:.userInitiated) { let result=try CaptureRecognition.recognize(image);return ([result.text]+result.codes).filter{!$0.isEmpty}.joined(separator:"\n") }.value},
             save:(CaptureDocument,CaptureSaveDestination,Double)async throws->URL={document,destination,quality in try await Task.detached(priority:.userInitiated) {try CaptureImageSave.save(document,to:destination,quality:quality)}.value}) async -> Bool {
        guard !running else { issue=tr(CaptureSaveFailure.busy.localizedDescription);return false }
        guard value.valid else { issue=tr(CaptureSaveFailure.invalidSettings.localizedDescription);return false }
        running=true;issue=nil;saved=[];completed=[];defer{running=false}
        let document=CaptureDocument(image:image)
        var pinned=false
        do {
            try Task.checkCancellation()
            if value.autoSave { saved.append(try await save(document,value.automatic,value.quality));completed.append("automaticSave") }
            for step in value.after {
                try Task.checkCancellation()
                switch step {
                case .copyImage:try copyImage(document.data())
                case .copyText:
                    let text=try await recognize(image);try Task.checkCancellation()
                    guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw CaptureSaveFailure.noText };try copyText(text)
                case .quickSave:saved.append(try await save(document,value.quick,value.quality))
                case .pin:try pin(image);pinned=true
                }
                completed.append(step.rawValue)
            }
            issue=nil;return true
        } catch is CancellationError { return false }
        catch {
            issue=captureFailureMessage(error)
            // Keep the captured pixels accessible on any failed chain, including a copy/save-only chain.
            if !pinned && !Task.isCancelled { do {try pin(image)} catch {issue=(issue ?? "")+"\n"+captureFailureMessage(error)} }
            return false
        }
    }
    func quickSave(_ document:CaptureDocument) throws -> URL {
        let value=try snapshot(),url=try CaptureImageSave.save(document,to:value.quick,quality:value.quality);saved=[url];return url
    }
}
