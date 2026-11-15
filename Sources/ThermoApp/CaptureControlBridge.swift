import AgentCore
import CaptureControlAdapter
import ModuleKit

@MainActor enum CaptureControlBridge {
    static func cancelActive(){BuiltinNativeFeatures.capture.makeControl(AppModels.shared.nativeFeatures).cancelActive()}
    static func handle(_ request:AppControlRequest) async->AppControlResponse {
        await CaptureControlEnvelope.handle(request,control:BuiltinNativeFeatures.capture.makeControl(AppModels.shared.nativeFeatures))
    }
}
