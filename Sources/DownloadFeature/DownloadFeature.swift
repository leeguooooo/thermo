import ModuleKit
import NativeFeatureAPI
import SwiftUI
import ThermoL10n

@MainActor package protocol DownloadPresentation: AnyObject {
    var mainWindowActive: Bool { get }
    func showDownloadPage()
}
package enum DownloadFeature {
    package static func registration(presentation: @escaping @MainActor @Sendable () -> any DownloadPresentation) -> NativeFeatureDefinition {
        .init(manifest: BuiltinModuleManifests.download,runsInBackground:true,ui:.init(sidebarLocations:[.software]), resolveLegacyPage:{argument in argument=="yunx" || argument.hasPrefix("yunx:") ? .init(BuiltinModuleManifests.download.id,"home"):nil},makeSession: { DownloadSession(availability:$0,presentation:presentation()) })
    }
}
@MainActor final class DownloadSession: NativeFeatureSession {
    private let availability: FeatureAvailability
    private let presentation: any DownloadPresentation
    private let makeModel: @MainActor (@escaping () -> Bool) -> YunXDownloadModel
    private let makeSetup: @MainActor (@escaping () -> Bool) -> YunXChromeUseSetup
    private let makePrompt: @MainActor (@escaping ()->Bool,@escaping ()->Bool,@escaping (YunXClipboardHit)->Void)->YunXClipboardPrompt
    private var storedModel: YunXDownloadModel?
    private var storedSetup: YunXChromeUseSetup?
    private var storedPrompt: YunXClipboardPrompt?
    init(availability:FeatureAvailability,presentation:any DownloadPresentation,
         makeModel:@escaping @MainActor (@escaping ()->Bool)->YunXDownloadModel = {YunXDownloadModel(enabled:$0)},
         makeSetup:@escaping @MainActor (@escaping ()->Bool)->YunXChromeUseSetup = {YunXChromeUseSetup(enabled:$0)},
         makePrompt:@escaping @MainActor (@escaping ()->Bool,@escaping ()->Bool,@escaping (YunXClipboardHit)->Void)->YunXClipboardPrompt = {YunXClipboardPrompt(enabled:$0,appWindowActive:$1,open:$2)}) {
        self.availability=availability;self.presentation=presentation;self.makeModel=makeModel;self.makeSetup=makeSetup;self.makePrompt=makePrompt
    }
    private var model:YunXDownloadModel {
        if let storedModel{return storedModel}
        let availability=availability,model=makeModel{availability.acceptsWork}
        storedModel=model;return model
    }
    private var setup:YunXChromeUseSetup {
        if let storedSetup{return storedSetup}
        let availability=availability,setup=makeSetup{availability.acceptsWork}
        storedSetup=setup;return setup
    }
    private var prompt:YunXClipboardPrompt {
        if let storedPrompt{return storedPrompt}
        let availability=availability,presentation=presentation
        let prompt=makePrompt({availability.acceptsWork},{presentation.mainWindowActive},{[weak self] hit in
            guard let self,self.availability.acceptsWork else{return}
            self.presentation.showDownloadPage()
            let model=self.model
            model.work.runOnMain{await model.openCopied(hit.link,passcode:hit.passcode)}
        })
        storedPrompt=prompt;return prompt
    }
    func start() {
        guard availability.acceptsWork else{return}
        prompt.refresh()
        let setup=setup
        setup.work.runOnMain{[weak setup] in await setup?.offerOnLaunch()}
    }
    func shutdown() {storedPrompt?.stop();storedModel?.shutdown();storedSetup?.stopFeature()}
    func ui(_ surface:NativeUISurface,navigation:NativeNavigation)->AnyView? {
        guard availability.acceptsWork,case let .sidebar(location,_,rows)=surface,location == .software else{return nil}
        return AnyView(rows(.init(route:.init(BuiltinModuleManifests.download.id,"home"),tint:.blue)))
    }
    func page(_ route:NativeFeatureRoute,navigation:NativeNavigation)->AnyView? {
        let entry=route.entry
        guard availability.acceptsWork,entry=="home" else{return nil}
        return AnyView(YunXDownloadPage(model:model,setup:setup,refreshClipboard:{[weak self] in
            guard let self,self.availability.acceptsWork else{return}
            self.prompt.refresh()
        }))
    }
    var status:NativeFeatureStatus {.init(modelLoaded:storedModel != nil || storedSetup != nil,snapshotReady:storedModel != nil)}
    func retireVisibility() {}
    func quitBlocker()->NativeFeatureBlocker? {
        guard storedModel?.canStopFeature == false || storedSetup?.canStopFeature == false else{return nil}
        return .init(reason:tr("Wait for downloads, sign-in or tool installation before switching this feature off."),route:.init(BuiltinModuleManifests.download.id,"home"))
    }
    func prepareStop()throws->NativeFeatureDrain {
        guard storedModel?.canStopFeature != false,storedSetup?.canStopFeature != false else {
            throw NativeFeatureBusy(tr("Wait for downloads, sign-in or tool installation before switching this feature off."))
        }
        let model=storedModel,setup=storedSetup
        model?.stopFeature();setup?.stopFeature();storedPrompt?.stop()
        return .init{[weak self] in
            await model?.finishFeatureStop();await setup?.finishFeatureStop()
            if self?.storedModel === model {self?.storedModel=nil}
            if self?.storedSetup === setup {self?.storedSetup=nil}
            self?.storedPrompt=nil
        }
    }
}
