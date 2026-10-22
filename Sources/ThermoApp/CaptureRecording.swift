import AppKit
import AVKit
import CaptureCore
import ScreenCaptureKit
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers

private func recordingClock() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

private final class RecordingOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: CaptureMovieWriter
    let failure: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var reported = false
    init(writer: CaptureMovieWriter, failure: @escaping @Sendable (Error) -> Void) { self.writer = writer; self.failure = failure }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        do {
            if type == .screen {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
                      let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue:raw) == .complete,
                      let image = sample.imageBuffer else { return }
                try writer.appendVideo(image,at:CMSampleBufferGetPresentationTimeStamp(sample))
            } else if type == .audio { try writer.appendAudio(sample) }
        } catch { report(error) }
    }
    func stream(_ stream: SCStream,didStopWithError error:Error) { report(error) }
    private func report(_ error:Error) {
        lock.lock(); let first = !reported; reported = true; lock.unlock()
        if first { failure(error) }
    }
}

@MainActor final class CaptureRecordingModel: ObservableObject {
    enum Phase { case ready, starting, recording, paused, stopping, preview, failed }
    enum Quality: String, CaseIterable { case compact, standard, high }
    static var defaultStore: CaptureRecordingDraftStore {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Thermo/CaptureDrafts",isDirectory:true)
        return CaptureRecordingDraftStore(root:root)
    }
    @Published private(set) var phase = Phase.ready
    @Published var issue: String?
    @Published var fps = 30
    @Published var quality: Quality = .standard
    @Published var systemAudio = false
    @Published var showsCursor = true
    @Published var delay = 3
    @Published private(set) var seconds = 0.0
    @Published private(set) var dropped = 0
    @Published private(set) var player: AVPlayer?
    @Published var duration = 0.0
    @Published var trimStart = 0.0
    @Published var trimEnd = 0.0
    @Published var speed = 1.0
    @Published var format: CaptureMovieFormat = .mp4
    @Published var animationFPS = 16
    @Published var animationSize = 1280
    @Published private(set) var savedURL: URL?
    @Published private(set) var exporting = false
    @Published private(set) var drafts: [CaptureRecordingDraft] = []
    private let region: CaptureRegionSelector.Region?
    let store: CaptureRecordingDraftStore
    private var draft: CaptureRecordingDraft?
    private(set) var source: URL?
    private var stream: SCStream?
    private var output: RecordingOutput?
    private var writer: CaptureMovieWriter?
    private var startTask: Task<Void,Never>?
    private var stopTask: Task<Void,Never>?
    private var timer: Timer?
    weak var window: NSWindow?
    weak var pendingSavePanel: NSSavePanel?
    init(region: CaptureRegionSelector.Region?, store: CaptureRecordingDraftStore? = nil) {
        self.region = region; self.store = store ?? Self.defaultStore; refreshDrafts()
    }
    var active: Bool { [.starting,.recording,.paused,.stopping].contains(phase) }
    var currentDraft: CaptureRecordingDraft? { draft }
    func refreshDrafts() {
        do { drafts = try store.list().filter { $0.id != draft?.id } } catch { issue = tr(error.localizedDescription) }
    }
    func start() {
        guard let region, !active, !exporting else { return }
        issue = nil; phase = .starting; player?.pause(); player = nil; source = nil; draft = nil
        let chosenFPS = fps, quality = quality, audio = systemAudio, cursor = showsCursor, delay = delay
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                for remaining in (0..<delay).reversed() {
                    self.seconds = Double(remaining+1)
                    try await Task.sleep(nanoseconds:1_000_000_000)
                }
                let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                try Task.checkCancellation()
                guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else { throw CaptureFailure.captureFailed }
                let filter = SCContentFilter(display:display,excludingApplications:content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier },exceptingWindows:[])
                let scale = min(region.scale,4096/max(region.rect.width,region.rect.height))
                let width = max(2,Int(region.rect.width*scale)/2*2), height = max(2,Int(region.rect.height*scale)/2*2)
                let draft = try self.store.create(); self.draft = draft
                let rate = quality == .compact ? 0.07 : (quality == .high ? 0.3 : 0.15)
                let writer = try CaptureMovieWriter(url:self.store.movie(draft.id),width:width,height:height,fps:chosenFPS,bitRate:min(100_000_000,max(100_000,Int(Double(width*height*chosenFPS)*rate))),systemAudio:audio)
                self.writer = writer
                let output = RecordingOutput(writer:writer) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.active, self.draft?.id == draft.id else { return }
                        self.issue = tr(error.localizedDescription); await self.stop()
                    }
                }
                let config = SCStreamConfiguration(); config.sourceRect = region.rect
                config.width = width; config.height = height; config.minimumFrameInterval = CMTime(value:1,timescale:Int32(chosenFPS))
                config.queueDepth = 5; config.showsCursor = cursor; config.pixelFormat = kCVPixelFormatType_32BGRA
                config.capturesAudio = audio; config.excludesCurrentProcessAudio = true; config.sampleRate = 48_000; config.channelCount = 2
                let stream = SCStream(filter:filter,configuration:config,delegate:output)
                try stream.addStreamOutput(output,type:.screen,sampleHandlerQueue:DispatchQueue(label:"dev.thermo.recording.frames"))
                if audio { try stream.addStreamOutput(output,type:.audio,sampleHandlerQueue:DispatchQueue(label:"dev.thermo.recording.audio")) }
                self.stream = stream; self.output = output
                try await stream.startCapture(); try Task.checkCancellation()
                self.seconds = 0; self.dropped = 0; self.phase = .recording
                self.timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let writer = self.writer else { return }
                        let values = writer.statistics(at:recordingClock()); self.seconds = values.seconds; self.dropped = values.droppedFrames
                    }
                }
            } catch {
                if let stream = self.stream { try? await stream.stopCapture() }
                self.writer?.cancel(); self.writer = nil; self.stream = nil; self.output = nil
                if let draft = self.draft, !FileManager.default.fileExists(atPath:self.store.movie(draft.id).path) {
                    try? self.store.discard(draft.id); self.draft = nil
                }
                if error is CancellationError { self.phase = .ready }
                else { self.phase = .failed; self.issue = tr(error.localizedDescription) }
            }
            self.startTask = nil
        }
    }
    func togglePause() {
        if phase == .recording { writer?.pause(at:recordingClock()); phase = .paused }
        else if phase == .paused { writer?.resume(at:recordingClock()); phase = .recording }
    }
    func playPreview() {
        player?.seek(to:CMTime(seconds:trimStart,preferredTimescale:60000),toleranceBefore:.zero,toleranceAfter:.zero)
        player?.playImmediately(atRate:Float(speed))
    }
    func stop() async {
        if phase == .starting { startTask?.cancel(); await startTask?.value; return }
        if let stopTask { await stopTask.value; return }
        guard phase == .recording || phase == .paused, let writer else { return }
        phase = .stopping; timer?.invalidate(); timer = nil
        let stopTime = recordingClock()
        stopTask = Task { [weak self] in
            guard let self else { return }
            if let stream = self.stream {
                do { try await stream.stopCapture() } catch { if self.issue == nil { self.issue = tr(error.localizedDescription) } }
            }
            do {
                let source = try await writer.finish(at:stopTime)
                if var draft = self.draft { draft.status = .ready; try self.store.update(draft); self.draft = draft }
                await self.preview(source)
            } catch { self.phase = .failed; self.issue = tr(error.localizedDescription) }
            self.writer = nil; self.stream = nil; self.output = nil; self.stopTask = nil; self.refreshDrafts()
        }
        await stopTask?.value
    }
    func preview(_ url:URL) async {
        guard !active || phase == .stopping else { return }
        do {
            let asset = AVURLAsset(url:url)
            guard try await asset.load(.isPlayable) else { throw CaptureMovieFailure.encoding("The recording draft cannot be played.") }
            let duration = try await asset.load(.duration).seconds
            guard duration.isFinite, duration > 0 else { throw CaptureMovieFailure.noFrames }
            player?.pause(); player = AVPlayer(playerItem:AVPlayerItem(asset:asset)); source = url
            self.duration = duration; trimStart = 0; trimEnd = duration; phase = .preview
        } catch { issue = tr(error.localizedDescription); phase = .failed }
    }
    func reopen(_ draft:CaptureRecordingDraft) {
        guard !active, !exporting else { return }; self.draft = draft
        Task { await preview(store.movie(draft.id)); refreshDrafts() }
    }
    func discard(_ draft:CaptureRecordingDraft) {
        guard !active, !exporting else { return }
        let alert = NSAlert(); alert.messageText = tr("Discard recording draft?")
        alert.informativeText = tr("The local draft will be removed. Exported files are kept.")
        alert.addButton(withTitle:tr("Discard")); alert.addButton(withTitle:tr("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.discard(draft.id)
            if self.draft?.id == draft.id { player?.pause(); player = nil; source = nil; self.draft = nil; phase = .ready }
            refreshDrafts()
        } catch { issue = tr(error.localizedDescription) }
    }
    func export() {
        guard !exporting, let source, let window else { return }
        NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil)
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:format.fileExtension) ?? .data]
        pendingSavePanel = panel
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Thermo-recording."+format.fileExtension
        var options = CaptureMovieExport.Options(); options.format = format; options.start = trimStart; options.end = trimEnd; options.speed = speed; options.fps = animationFPS; options.maxDimension = animationSize
        exporting = true; issue = nil; savedURL = nil
        Task {
            defer { exporting = false }
            let response = await withCheckedContinuation { continuation in panel.beginSheetModal(for:window) { continuation.resume(returning:$0) } }
            guard response == .OK, let url = panel.url else { return }
            do { try await CaptureMovieExport.export(source:source,to:url,options:options); savedURL = url }
            catch { issue = tr(error.localizedDescription) }
        }
    }
}

@MainActor final class CaptureRecordingWindow: NSWindowController, NSWindowDelegate {
    let model: CaptureRecordingModel
    init(region:CaptureRegionSelector.Region?, store:CaptureRecordingDraftStore? = nil) {
        model = CaptureRecordingModel(region:region,store:store)
        let panel = NSPanel(contentRect:NSRect(x:0,y:0,width:660,height:620),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
        panel.title = tr("Screen recording"); panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false; panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]; panel.center()
        super.init(window:panel); panel.delegate = self
        model.window = panel
        panel.contentView = NSHostingView(rootView:CaptureRecordingView(model:model,hasRegion:region != nil))
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) is not used") }
    override func showWindow(_ sender:Any?) {
        super.showWindow(sender); NSApp.activate(ignoringOtherApps:true); window?.makeKeyAndOrderFront(sender)
    }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        if model.active || model.exporting { NSSound.beep(); model.issue = tr("Stop recording or wait for export before closing this window."); return false }
        model.player?.pause(); return true
    }
}

private struct CaptureRecordingView: View {
    @ObservedObject var model: CaptureRecordingModel
    let hasRegion:Bool
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            if !hasRegion && model.player == nil && model.drafts.isEmpty { Text(tr("No recording drafts yet.")).foregroundStyle(.secondary); Spacer() }
            if let player = model.player {
                RecordingPlayer(player:player).frame(minHeight:160,maxHeight:.infinity)
                HStack {
                    Button(tr("Play from trim start")) { model.playPreview() }
                    Button(tr("Pause")) { model.player?.pause() }
                }
                HStack {
                    Text(tr("Trim start")); TextField("",value:$model.trimStart,format:.number).frame(width:70)
                    Text(tr("Trim end")); TextField("",value:$model.trimEnd,format:.number).frame(width:70)
                    Picker(tr("Speed"),selection:$model.speed) { ForEach([0.25,0.5,1,1.5,2,4],id:\.self) { Text(String(format:"%g×",$0)).tag($0) } }.frame(width:140)
                }.textFieldStyle(.roundedBorder)
                HStack {
                    Picker(tr("Format"),selection:$model.format) { ForEach(CaptureMovieFormat.allCases,id:\.self) { Text($0.rawValue.uppercased()).tag($0) } }
                    Button(tr("Export recording…")) { model.export() }.disabled(model.exporting || model.trimStart < 0 || model.trimEnd <= model.trimStart || model.trimEnd > model.duration)
                    if model.exporting { ProgressView().controlSize(.small) }
                }.disabled(model.exporting)
                if model.format != .mp4 {
                    HStack {
                        Picker(tr("Animation frame rate"),selection:$model.animationFPS) { ForEach([5,16,24,30,60],id:\.self) { Text("\($0) FPS").tag($0) } }
                        Picker(tr("Maximum dimension"),selection:$model.animationSize) { ForEach([640,1280,1920,4096],id:\.self) { Text("\($0) px").tag($0) } }
                    }.disabled(model.exporting)
                }
                HStack {
                    if hasRegion { Button(tr("Record again")) { model.start() } }
                    if let draft = model.currentDraft { Button(tr("Discard current draft")) { model.discard(draft) } }
                }.disabled(model.exporting)
            } else if hasRegion {
                Text(tr("Quick recording · MP4 source")).font(.headline)
                HStack {
                    Picker(tr("Frame rate"),selection:$model.fps) { ForEach([5,16,24,30,60],id:\.self) { Text("\($0) FPS").tag($0) } }
                    Picker(tr("Quality"),selection:$model.quality) { ForEach(CaptureRecordingModel.Quality.allCases,id:\.self) { Text(tr($0.rawValue.capitalized)).tag($0) } }
                }.disabled(model.active)
                HStack {
                    Toggle(tr("System audio"),isOn:$model.systemAudio)
                    Toggle(tr("Show cursor"),isOn:$model.showsCursor)
                    Picker(tr("Start delay"),selection:$model.delay) { ForEach([0,3,5],id:\.self) { Text("\($0) s").tag($0) } }.frame(width:150)
                }.disabled(model.active)
                Text(tr("Thermo windows are excluded. The recording is saved as a local draft.")).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Text(String(format:"%02d:%05.2f",Int(model.seconds)/60,model.seconds.truncatingRemainder(dividingBy:60))).font(.system(size:38,design:.monospaced)).frame(maxWidth:.infinity)
                if model.phase == .paused { Text(tr("Paused")).frame(maxWidth:.infinity) }
                if model.dropped > 0 { Text(tr("Dropped video frames: %@",String(model.dropped))).font(.caption).foregroundStyle(.orange) }
                HStack {
                    Button(tr("Start recording")) { model.start() }.disabled(model.active)
                    Button(tr(model.phase == .paused ? "Resume" : "Pause")) { model.togglePause() }.disabled(model.phase != .recording && model.phase != .paused)
                    Button(tr("Stop recording")) { Task { await model.stop() } }.disabled(!model.active || model.phase == .stopping)
                    if model.phase == .starting || model.phase == .stopping { ProgressView().controlSize(.small) }
                }
            }
            if !model.drafts.isEmpty {
                Divider(); Text(tr("Recording drafts")).font(.headline)
                ScrollView {
                    VStack(alignment:.leading) {
                        ForEach(model.drafts) { draft in
                            HStack {
                                Text(draft.createdAt,style:.date); Text(draft.createdAt,style:.time)
                                if draft.status != .ready { Text(tr("Interrupted")).foregroundStyle(.orange) }
                                Spacer()
                                Button(tr("Preview")) { model.reopen(draft) }
                                Button(tr("Discard")) { model.discard(draft) }
                            }
                        }
                    }
                }.frame(maxHeight:100).disabled(model.active || model.exporting)
            }
            if let issue = model.issue { Text(issue).foregroundStyle(.red).textSelection(.enabled).font(.callout) }
            if let url = model.savedURL { Text(tr("Saved to %@",url.path)).font(.caption).textSelection(.enabled) }
            Text(tr("Drafts stay on this Mac until you discard them. Exported files are separate.")).font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(minWidth:600,minHeight:400)
    }
}

private struct RecordingPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView(); view.controlsStyle = .inline; view.videoGravity = .resizeAspect; view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) { if view.player !== player { view.player = player } }
}
