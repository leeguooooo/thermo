import AppKit
import CaptureCore
import ThermoL10n

@MainActor final class CaptureTranslationModel:ObservableObject {
    enum Mode:String,CaseIterable {case text,image}
    @Published var source="" {didSet{if source != oldValue && !updatingSource{invalidate()}}}
    @Published var targetLanguage:String {didSet{if targetLanguage != oldValue && !updatingSource{invalidate()}}}
    @Published var translated=""
    @Published var mode:Mode = .text {didSet{if mode != oldValue{invalidate()}}}
    @Published var regions:[CaptureTranslationRegion]=[]
    @Published var regionTranslations:[String]=[]
    @Published private(set) var busy=false
    @Published private(set) var preparingImage=false
    @Published var issue:String?
    @Published var image:CGImage?
    @Published private(set) var resultReady=false
    let service:CaptureTranslationService
    var showSettings:(()->Void)?
    var openText:((String)throws->Void)?
    var openImage:((CGImage)throws->Void)?
    private var task:Task<Void,Never>?
    private var generation=UUID()
    private var updatingSource=false
    private let recognizeImage:@Sendable(CGImage)async throws->[CaptureTranslationRegion]
    init(service:CaptureTranslationService,recognizeImage:@escaping @Sendable(CGImage)async throws->[CaptureTranslationRegion]={image in try await Task.detached(priority:.userInitiated){try CaptureTranslationImage.recognize(image)}.value}){self.service=service;self.recognizeImage=recognizeImage;targetLanguage=service.settings.targetLanguage}
    private func invalidate(){cancel();resultReady=false}
    func configurationChanged(){updatingSource=true;targetLanguage=service.settings.targetLanguage;updatingSource=false;if !preparingImage{invalidate()}}
    func setText(_ text:String){cancel();image=nil;regions=[];regionTranslations=[];mode = .text;source=text;translated="";issue=nil}
    func setImage(_ image:CGImage){
        cancel();self.image=image;source="";regions=[];regionTranslations=[];translated="";issue=nil;busy=true;preparingImage=true
        let token=UUID();generation=token
        task=Task{[weak self] in guard let self else{return};defer{if self.generation == token{self.busy=false;self.preparingImage=false;self.task=nil}}
            do{let rows=try await self.recognizeImage(image);try Task.checkCancellation();guard self.generation == token else{return}
                self.regions=rows;self.updatingSource=true;self.source=rows.map(\.text).joined(separator:"\n");self.updatingSource=false
            }catch is CancellationError{}catch{if self.generation == token{self.issue=captureFailureMessage(error)}}
        }
    }
    func translate(){
        guard !busy else{return};let inputs=mode == .image ? regions.map(\.text) : [source]
        let token=UUID(),profile=service.settings;generation=token;busy=true;issue=nil;resultReady=false
        task=Task{[weak self] in guard let self else{return};defer{if self.generation == token{self.busy=false;self.task=nil}}
            do{let values=try await self.service.translate(inputs,targetLanguage:self.targetLanguage);try Task.checkCancellation();guard self.generation == token else{return}
                guard self.service.settings == profile else{throw CaptureTranslationFailure.invalidSettings}
                self.regionTranslations=self.mode == .image ? values : [];self.translated=values.joined(separator:"\n");self.resultReady=true
            }catch is CancellationError{}catch{if self.generation == token{self.issue=captureFailureMessage(error)}}
        }
    }
    func cancel(){generation=UUID();task?.cancel();task=nil;busy=false;preparingImage=false}
    func createPin(){
        do {
            guard resultReady else{throw CaptureTranslationFailure.invalidResponse}
            if mode == .image,let image {
                guard let openImage else{throw CaptureActionFailure.noPin};try openImage(CaptureTranslationImage.overlay(image,regions:regions,translations:regionTranslations))
            }else{
                guard !translated.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else{throw CaptureTranslationFailure.invalidInput}
                guard let openText else{throw CaptureActionFailure.noPin};try openText(translated)
            };issue=nil
        }catch{issue=captureFailureMessage(error)}
    }
}
