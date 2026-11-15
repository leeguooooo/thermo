import AgentCore
import CaptureControlAdapter
import ModuleKit

@MainActor enum CaptureControlBridge {
    static func cancelActive(){ShellState.shared.assembly.makeCaptureControl(ShellState.shared.nativeFeatures).cancelActive()}
    static func handle(_ request:AppControlRequest) async->AppControlResponse {
        await CaptureControlEnvelope.handle(request,control:ShellState.shared.assembly.makeCaptureControl(ShellState.shared.nativeFeatures))
    }
}
