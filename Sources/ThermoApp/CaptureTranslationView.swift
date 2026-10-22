import AppKit
import SwiftUI
import CaptureCore
import ThermoL10n

struct CaptureTranslationSettingsView:View {
    @ObservedObject var service:CaptureTranslationService
    @State private var draft=CaptureTranslationSettings()
    @State private var appID=""
    @State private var secret=""
    @State private var savedKey=false
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text(tr("Translation service")).font(.title2.bold())
            if let issue=service.issue{Text(issue).foregroundStyle(.red).textSelection(.enabled)}
            Toggle(tr("Enable translation requests"),isOn:$draft.enabled)
            Picker(tr("Translation provider"),selection:$draft.provider){Text(tr("Youdao batch translation")).tag(CaptureTranslationSettings.Provider.youdao);Text(tr("Baidu translation")).tag(CaptureTranslationSettings.Provider.baidu);Text(tr("Chat Completions compatible")).tag(CaptureTranslationSettings.Provider.chatCompletions)}
            if draft.provider == .chatCompletions {
                TextField(tr("API endpoint"),text:$draft.endpoint).textFieldStyle(.roundedBorder)
                TextField(tr("Translation model ID"),text:$draft.model).textFieldStyle(.roundedBorder)
            }else{Text(draft.serviceURL?.absoluteString ?? "").font(.caption).textSelection(.enabled)}
            HStack{TextField(tr("Source language code"),text:$draft.sourceLanguage);TextField(tr("Target language code"),text:$draft.targetLanguage)}.textFieldStyle(.roundedBorder)
            Text(tr("Use auto for source detection; zh, en and ja are common target codes. Youdao maps zh to zh-CHS.")).font(.caption).foregroundStyle(.secondary)
            if draft.provider != .chatCompletions{TextField(tr("Translation App ID"),text:$appID).textFieldStyle(.roundedBorder)}
            SecureField(tr("Translation secret or API key"),text:$secret).textFieldStyle(.roundedBorder)
            Text(tr(savedKey ? "A key is saved for this endpoint. Leave the secret blank to keep it." : "No key is saved for this endpoint.")).font(.caption)
            Text(tr("Click Translate or invoke a translation action to send text. Image OCR stays on this Mac; image pixels are not uploaded. Keys are stored in Keychain and scoped to this endpoint.")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button(tr("Forget translation credentials")){if service.forgetCredential(for:draft){draft.enabled=false;loadCredential()}}
                Spacer()
                Button(tr("Apply translation settings")) {
                    if secret.isEmpty,draft.provider != .chatCompletions,let existing=try? service.credential(for:draft),existing.appID != appID.trimmingCharacters(in:.whitespacesAndNewlines){service.issue=tr("Enter the matching secret when changing the App ID.");return}
                    let credential=secret.isEmpty ? nil : CaptureTranslationCredential(appID:appID.trimmingCharacters(in:.whitespacesAndNewlines),secret:secret)
                    if service.apply(draft,newCredential:credential){secret="";loadCredential()}
                }
            }
        }.padding(16).frame(minWidth:650).onAppear{draft=service.settings;loadCredential()}
        .onChange(of:draft.provider){_ in secret="";loadCredential()}.onChange(of:draft.endpoint){_ in secret="";loadCredential()}
    }
    private func loadCredential(){do{let credential=try service.credential(for:draft);appID=credential?.appID ?? "";savedKey=credential != nil}catch{service.issue=captureFailureMessage(error);savedKey=false;appID=""}}
}
struct CaptureTranslationView:View {
    @ObservedObject var model:CaptureTranslationModel
    @ObservedObject var service:CaptureTranslationService
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack{Text(tr("Translate text and images")).font(.title2.bold());Spacer();Button(tr("Translation settings…")){model.showSettings?()}}
            if !service.settings.enabled{Text(tr("Enable translation in settings before sending.")).foregroundStyle(.secondary)}
            HStack {
                Picker(tr("Translation output"),selection:$model.mode){Text(tr("Translated text")).tag(CaptureTranslationModel.Mode.text);if model.image != nil{Text(tr("Image overlay")).tag(CaptureTranslationModel.Mode.image)}}.pickerStyle(.segmented).disabled(model.busy)
                TextField(tr("Target language for this translation"),text:$model.targetLanguage).frame(width:120).textFieldStyle(.roundedBorder).disabled(model.busy)
            }
            if model.mode == .text {
                HStack(alignment:.top){
                    VStack(alignment:.leading){Text(tr("Translation source"));TextEditor(text:$model.source).font(.system(.body,design:.monospaced)).disabled(model.busy)}
                    VStack(alignment:.leading){Text(tr("Translation result"));TextEditor(text:$model.translated).font(.system(.body,design:.monospaced)).disabled(model.busy)}
                }.frame(minHeight:160)
            }else{
                ScrollView{VStack(alignment:.leading,spacing:8){ForEach(Array(model.regions.enumerated()),id:\.element.id){index,region in
                    HStack(alignment:.top){Text(region.text).frame(maxWidth:.infinity,alignment:.leading);if model.regionTranslations.indices.contains(index){TextField(tr("Region translation"),text:$model.regionTranslations[index]).textFieldStyle(.roundedBorder).frame(maxWidth:.infinity)}else{Text(tr("Not translated yet")).foregroundStyle(.secondary).frame(maxWidth:.infinity)}}
                }}}.frame(minHeight:160)
            }
            if !model.resultReady && !model.translated.isEmpty{Text(tr("Previous result; translate again before creating a pin.")).font(.caption).foregroundStyle(.secondary)}
            if let issue=model.issue{Text(issue).foregroundStyle(.red).textSelection(.enabled)}
            Text(String(format:tr("Text destination: %@"),service.settings.serviceURL?.absoluteString ?? "")).font(.caption).foregroundStyle(.secondary)
            HStack{
                if model.busy{ProgressView().controlSize(.small);Text(tr(model.preparingImage ? "Recognizing text locally…" : "Translating…")).font(.caption);Button(tr("Cancel translation")){model.cancel()}}
                Button(tr("Translate")){model.translate()}.disabled(model.busy || service.running || !service.settings.enabled)
                Button(tr("Copy translation")){NSPasteboard.general.clearContents();NSPasteboard.general.setString(model.mode == .image ? model.regionTranslations.joined(separator:"\n") : model.translated,forType:.string)}.disabled(!model.resultReady || model.translated.isEmpty)
                Button(tr("Create translated pin")){model.createPin()}.disabled(!model.resultReady || model.busy)
                Spacer()
            }
        }.padding(16).frame(minWidth:760,minHeight:540).onChange(of:service.settings){_ in model.configurationChanged()}
    }
}
@MainActor final class CaptureTranslationWindow:NSWindowController,NSWindowDelegate {
    let model:CaptureTranslationModel
    init(model:CaptureTranslationModel){self.model=model;let window=NSWindow(contentRect:NSRect(x:0,y:0,width:900,height:760),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false);window.title=tr("Translate text and images");window.isReleasedWhenClosed=false;window.level = .floating;window.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary];window.contentView=NSHostingView(rootView:CaptureTranslationView(model:model,service:model.service));window.center();super.init(window:window);window.delegate=self}
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func windowWillClose(_ notification:Notification){model.cancel()}
}
