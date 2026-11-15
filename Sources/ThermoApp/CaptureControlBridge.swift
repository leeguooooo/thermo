import AgentCore
import CaptureControlAdapter
import ModuleKit

@MainActor enum CaptureControlBridge {
    static func cancelActive(){AppModels.shared.assembly.makeCaptureControl(AppModels.shared.nativeFeatures).cancelActive()}
    static func handle(_ request:AppControlRequest) async->AppControlResponse {
        await CaptureControlEnvelope.handle(request,control:AppModels.shared.assembly.makeCaptureControl(AppModels.shared.nativeFeatures))
    }
}
