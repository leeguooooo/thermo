// Real display capture QA with private drafts and pins. No helper, updater or global shortcuts.
@testable import ThermoApp
import AppKit
import AVFoundation
import CaptureCore
import SwiftUI

@MainActor final class LiveCaptureReview:ObservableObject {
    let root:URL
    let workspace:CaptureWorkspace
    @Published var permission=false
    @Published var selection="No recording region selected"
    var selector:CaptureRegionSelector?
    var recording:CaptureRecordingWindow?
    private var selected:CaptureRegionSelector.Region?
    private var timer:Timer?
    init(root:URL) {
        self.root=root
        workspace=CaptureWorkspace(pinSession:CapturePinSession(store:.init(root:root.appendingPathComponent("pins"))))
        workspace.saving=CaptureSaveModel(read:{nil},write:{_ in})
        timer=Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in MainActor.assumeIsolated {self?.probe()} }
        probe()
    }
    func choose() {
        guard selector == nil,recording?.model.active != true,recording?.model.exporting != true else{return}
        let picker=CaptureRegionSelector();selector=picker
        picker.select { [weak self] region in
            guard let self else{return};self.selector=nil
            guard let region else{self.selection="Selection cancelled";self.probe();return}
            self.selected=region;self.selection="Display \(region.displayID): \(region.rect) at \(region.scale)×"
            self.recording?.close()
            let window=CaptureRecordingWindow(region:region,store:CaptureRecordingDraftStore(root:self.root.appendingPathComponent("drafts")))
            self.recording=window;window.showWindow(nil);self.probe()
        }
    }
    func probe() {
        let granted=CGPreflightScreenCaptureAccess();if permission != granted {permission=granted}
        var r:[String:Any] = ["permissionGranted":granted,"selection":selection,"selecting":selector != nil,
            "displays":NSScreen.screens.map {screen -> [String:Any] in
                let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32) ?? 0
                return ["id":id,"name":screen.localizedName,"frame":NSStringFromRect(screen.frame),"quartzFrame":NSStringFromRect(CGDisplayBounds(id)),"scale":screen.backingScaleFactor]
            },"pins":workspace.pinSession.library.pins.map {pin -> [String:Any] in
                var value:[String:Any]=["id":pin.id.uuidString,"snapshot":pin.snapshotID.uuidString]
                if let document=try? workspace.pinSession.store.document(for:pin) {value["size"]=[document.image.width,document.image.height]}
                return value
            }]
        if let selected {r["selected"]=["displayID":selected.displayID,"rect":NSStringFromRect(selected.rect),"scale":selected.scale]}
        if let model=recording?.model {
            r["recording"]=["phase":String(describing:model.phase),"active":model.active,"mode":model.mode.rawValue,"seconds":model.seconds,"dropped":model.dropped,"duration":model.duration,"issue":model.issue ?? "","source":model.source?.path ?? "","draftID":model.currentDraft?.id.uuidString ?? "","drafts":model.drafts.count,"systemAudio":model.systemAudio,"camera":model.captureCamera,"microphone":model.captureMicrophone,"keyboard":model.recordKeyboard,"visible":recording?.window?.isVisible ?? false]
        }
        if let data=try? JSONSerialization.data(withJSONObject:r,options:[.prettyPrinted,.sortedKeys]) {try? data.write(to:root.appendingPathComponent("live-capture-probe.json"),options:.atomic)}
    }
}

struct LiveCaptureReviewView:View {
    @ObservedObject var model:LiveCaptureReview
    var body:some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Real display / recording QA").font(.title)
            Text(model.permission ? "Screen recording permission: granted" : "Screen recording permission: required")
            Button("Request screen recording permission") {CGRequestScreenCaptureAccess();model.probe()}
            Button("Choose recording display / region"){model.choose()}
            Text(model.selection).textSelection(.enabled)
            Text("Private drafts and pins only. Camera, microphone, keyboard and system audio start disabled.")
            CaptureScreenshotQA(workspace:model.workspace,root:model.root)
        }.padding(24)
    }
}
