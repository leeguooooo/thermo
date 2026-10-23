import AppKit
import AVKit
import CaptureCore
import ScreenCaptureKit
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers

private func recordingClock() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

private protocol RecordingDestination: AnyObject, Sendable {
    func appendVideo(_ buffer:CVPixelBuffer,at time:CMTime) throws -> Bool
    func appendAudio(_ sample:CMSampleBuffer) throws
    func pause(at time:CMTime)
    func resume(at time:CMTime)
    func statistics(at time:CMTime) -> CaptureMovieWriter.Statistics
    func finish(at time:CMTime) async throws -> URL
    func cancel()
}
extension CaptureMovieWriter: RecordingDestination {}
extension CaptureFrameArchive: RecordingDestination {}

private final class RecordingOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let writer: any RecordingDestination
    let failure: @Sendable (Error) -> Void
    private let lock = NSLock()
    private var reported = false
    init(writer: any RecordingDestination, failure: @escaping @Sendable (Error) -> Void) { self.writer = writer; self.failure = failure }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sample.isValid else { return }
        do {
            if type == .screen {
                guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],
                      let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue:raw) == .complete,
                      let image = sample.imageBuffer else { return }
                _=try writer.appendVideo(image,at:CMSampleBufferGetPresentationTimeStamp(sample))
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
    enum Phase { case ready, starting, recording, paused, stopping, rendering, preview, failed }
    enum Quality: String, CaseIterable { case compact, standard, high }
    static var defaultStore: CaptureRecordingDraftStore {
        let root = FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            .appendingPathComponent("Thermo/CaptureDrafts",isDirectory:true)
        return CaptureRecordingDraftStore(root:root)
    }
    @Published private(set) var phase = Phase.ready
    @Published var issue: String?
    @Published var mode:CaptureRecordingDraft.Mode = .quick
    @Published var fps = 30
    @Published var quality: Quality = .standard
    @Published var systemAudio = false
    @Published var recordKeyboard=false
    @Published var keyboardMode:CaptureKeyMode = .shortcuts
    private var keyboardMonitor:CaptureKeyboardMonitor?
    @Published var captureCamera=false
    @Published var captureMicrophone=false
    @Published var cameraID=""
    @Published var microphoneID=""
    @Published private(set) var cameraDevices:[CaptureDeviceChoice]=[]
    @Published private(set) var microphoneDevices:[CaptureDeviceChoice]=[]
    @Published private(set) var devicePreview:AVCaptureSession?
    private var devices:CaptureAVDevices?
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
    private var writer: (any RecordingDestination)?
    private var archive:CaptureFrameArchive?
    @Published private(set) var normalSource:CaptureFrameArchiveSource?
    @Published var normalEdits=CaptureNormalEdits()
    @Published private(set) var renderProgress=0.0
    private var renderTask:Task<Void,Never>?
    private var pointerTimer:Timer?
    private var pointerMonitor:Any?
    private var overlayWindow:NSWindowController?
    private var startTask: Task<Void,Never>?
    private var stopTask: Task<Void,Never>?
    private var exportTask:Task<Void,Never>?
    private var timer: Timer?
    weak var window: NSWindow?
    weak var pendingSavePanel: NSSavePanel?
    init(region: CaptureRegionSelector.Region?, store: CaptureRecordingDraftStore? = nil) {
        self.region = region; self.store = store ?? Self.defaultStore; refreshDrafts()
    }
    var active: Bool { [.starting,.recording,.paused,.stopping,.rendering].contains(phase) }
    var currentDraft: CaptureRecordingDraft? { draft }
    func refreshDrafts() {
        do { drafts = try store.list().filter { $0.id != draft?.id } } catch { issue = tr(error.localizedDescription) }
    }
    func start() {
        guard let region, !active, !exporting else { return }
        issue = nil; phase = .starting; player?.pause(); player = nil; source = nil; draft = nil; normalSource = nil; archive = nil; normalEdits=CaptureNormalEdits()
        let chosenFPS = fps, quality = quality, audio = systemAudio, cursor = showsCursor, delay = delay,mode=mode
        let camera=mode == .normal && captureCamera,microphone=mode == .normal && captureMicrophone
        let cameraID=cameraID,microphoneID=microphoneID,keys=mode == .normal && recordKeyboard,keyMode=keyboardMode
        startTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await CaptureAVDevices.authorize(camera:camera,microphone:microphone)
                if keys { try CaptureKeyboardMonitor.authorize() }
                let content = try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
                try Task.checkCancellation()
                guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else { throw CaptureFailure.captureFailed }
                let filter = SCContentFilter(display:display,excludingApplications:content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier },exceptingWindows:[])
                for remaining in (0..<delay).reversed() {
                    self.seconds = Double(remaining+1)
                    try await Task.sleep(nanoseconds:1_000_000_000)
                }
                let scale = min(region.scale,4096/max(region.rect.width,region.rect.height))
                let width = max(2,Int(region.rect.width*scale)/2*2), height = max(2,Int(region.rect.height*scale)/2*2)
                let draft = try self.store.create(mode:mode); self.draft = draft
                let rate = quality == .compact ? 0.07 : (quality == .high ? 0.3 : 0.15)
                let writer:any RecordingDestination
                if mode == .normal {
                    let archive=try CaptureFrameArchive(root:self.store.archive(draft.id),header:.init(width:width,height:height,fps:chosenFPS,codec:quality == .high ? .png : .jpeg,pixelScale:Double(width)/region.rect.width,keyboardCapture:keys ? keyMode : nil),jpegQuality:quality == .compact ? 0.65 : 0.9)
                    self.archive=archive; writer=archive; self.normalEdits.showCursor=cursor
                    if keys { var settings=CaptureKeyboardEdits();settings.mode=keyMode;self.normalEdits.keyboard=settings }
                    try self.normalEdits.save(to:archive.root)
                } else {
                    writer=try CaptureMovieWriter(url:self.store.movie(draft.id),width:width,height:height,fps:chosenFPS,bitRate:min(100_000_000,max(100_000,Int(Double(width*height*chosenFPS)*rate))),systemAudio:audio)
                }
                self.writer = writer
                let output = RecordingOutput(writer:writer) { [weak self] error in
                    Task { @MainActor in
                        guard let self, self.active, self.draft?.id == draft.id else { return }
                        self.issue = tr(error.localizedDescription); await self.stop()
                    }
                }
                let config = SCStreamConfiguration(); config.sourceRect = region.rect
                config.width = width; config.height = height; config.minimumFrameInterval = CMTime(value:1,timescale:Int32(chosenFPS))
                config.queueDepth = 5; config.showsCursor = mode == .quick && cursor; config.pixelFormat = kCVPixelFormatType_32BGRA
                config.capturesAudio = audio; config.excludesCurrentProcessAudio = true; config.sampleRate = 48_000; config.channelCount = 2
                let stream = SCStream(filter:filter,configuration:config,delegate:output)
                try stream.addStreamOutput(output,type:.screen,sampleHandlerQueue:DispatchQueue(label:"dev.thermo.recording.frames"))
                if audio { try stream.addStreamOutput(output,type:.audio,sampleHandlerQueue:DispatchQueue(label:"dev.thermo.recording.audio")) }
                self.stream = stream; self.output = output
                try await stream.startCapture(); try Task.checkCancellation()
                if (camera || microphone),let archive=self.archive {
                    let devices=CaptureAVDevices(archive:archive) { [weak self] error in
                        Task { @MainActor in
                            guard let self,self.active,self.draft?.id == draft.id else { return }
                            self.issue=tr(error.localizedDescription);await self.stop()
                        }
                    }
                    self.devices=devices
                    try await devices.start(camera:camera,microphone:microphone,cameraID:cameraID,microphoneID:microphoneID)
                    try Task.checkCancellation()
                    if camera { self.devicePreview=devices.session }
                }
                self.seconds = 0; self.dropped = 0; self.phase = .recording
                if mode == .normal { self.beginPointerTracking(region:region) }
                if keys,let archive=self.archive {
                    let monitor=CaptureKeyboardMonitor(mode:keyMode,archive:archive,active:{ [weak self] in self?.phase == .recording }) { [weak self] error in
                        Task { @MainActor in self?.issue=tr(error.localizedDescription);await self?.stop() }
                    }
                    self.keyboardMonitor=monitor;try monitor.start()
                }
                self.timer = Timer.scheduledTimer(withTimeInterval:0.25,repeats:true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let writer = self.writer else { return }
                        let values = writer.statistics(at:recordingClock()); self.seconds = values.seconds; self.dropped = values.droppedFrames
                    }
                }
            } catch {
                self.keyboardMonitor?.stop();self.keyboardMonitor=nil;self.endPointerTracking();self.timer?.invalidate();self.timer=nil
                if let stream = self.stream { try? await stream.stopCapture() }
                if let devices=self.devices { await devices.stop() };self.devices=nil;self.devicePreview=nil
                self.writer?.cancel();if let archive=self.archive { await archive.cancelAndWait() }
                self.writer = nil; self.archive=nil; self.stream = nil; self.output = nil
                if let draft = self.draft, draft.effectiveMode == .quick, !FileManager.default.fileExists(atPath:self.store.movie(draft.id).path) {
                    try? self.store.discard(draft.id); self.draft = nil
                }
                if error is CancellationError { self.phase = .ready }
                else { self.phase = .failed; self.issue = tr(error.localizedDescription) }
            }
            self.startTask = nil
        }
    }
    func refreshCaptureDevices() {
        if captureCamera { cameraDevices=CaptureAVDevices.choices(for:.video) }
        if captureMicrophone { microphoneDevices=CaptureAVDevices.choices(for:.audio) }
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
        if phase == .rendering { renderTask?.cancel();await renderTask?.value;return }
        if phase == .starting { startTask?.cancel(); await startTask?.value; return }
        if let stopTask { await stopTask.value; return }
        guard phase == .recording || phase == .paused, let writer else { return }
        phase = .stopping; timer?.invalidate(); timer = nil; endPointerTracking();keyboardMonitor?.stop();keyboardMonitor=nil
        let stopTime = recordingClock()
        stopTask = Task { [weak self] in
            guard let self else { return }
            if let stream = self.stream {
                do { try await stream.stopCapture() } catch { if self.issue == nil { self.issue = tr(error.localizedDescription) } }
            }
            if let devices=self.devices { await devices.stop() };self.devices=nil;self.devicePreview=nil
            do {
                let source = try await writer.finish(at:stopTime)
                if var draft = self.draft { draft.status = .ready; try self.store.update(draft); self.draft = draft }
                if self.draft?.effectiveMode == .normal {
                    self.normalSource=try CaptureFrameArchiveSource.load(source)
                    try self.normalEdits.save(to:source)
                    await self.renderNormalPreview()
                } else { await self.preview(source) }
            } catch { self.phase = .failed; self.issue = tr(error.localizedDescription) }
            self.writer = nil; self.archive=nil; self.stream = nil; self.output = nil; self.stopTask = nil; self.refreshDrafts()
        }
        await stopTask?.value
    }
    func preview(_ url:URL) async {
        guard !active || phase == .stopping || phase == .rendering else { return }
        do {
            let asset = AVURLAsset(url:url)
            guard try await asset.load(.isPlayable) else { throw CaptureMovieFailure.encoding("The recording draft cannot be played.") }
            let movieDuration = try await asset.load(.duration).seconds
            let duration = normalSource?.duration ?? movieDuration
            guard duration.isFinite, duration > 0 else { throw CaptureMovieFailure.noFrames }
            player?.pause(); player = AVPlayer(playerItem:AVPlayerItem(asset:asset)); source = url
            self.duration = duration; trimStart = 0; trimEnd = duration; phase = .preview
        } catch { issue = tr(error.localizedDescription); phase = .failed }
    }
    func reopen(_ draft:CaptureRecordingDraft) {
        guard !active, !exporting else { return }; self.draft = draft
        Task {
            if draft.effectiveMode == .normal {
                do { normalSource=try CaptureFrameArchiveSource.load(store.archive(draft.id));normalEdits=try CaptureNormalEdits.load(from:store.archive(draft.id));await renderNormalPreview() }
                catch { phase = .failed;issue=tr(error.localizedDescription) }
            } else { normalSource=nil;await preview(store.movie(draft.id)) }
            refreshDrafts()
        }
    }
    func discard(_ draft:CaptureRecordingDraft) {
        guard !active, !exporting else { return }
        let alert = NSAlert(); alert.messageText = tr("Discard recording draft?")
        alert.informativeText = tr("The local draft will be removed. Exported files are kept.")
        alert.addButton(withTitle:tr("Discard")); alert.addButton(withTitle:tr("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.discard(draft.id)
            if self.draft?.id == draft.id { player?.pause(); player = nil; source = nil; self.draft = nil; normalSource=nil; phase = .ready }
            refreshDrafts()
        } catch { issue = tr(error.localizedDescription) }
    }
    private func beginPointerTracking(region:CaptureRegionSelector.Region) {
        pointerTimer=Timer.scheduledTimer(withTimeInterval:1/60,repeats:true) { [weak self] _ in
            MainActor.assumeIsolated { self?.samplePointer(region:region) }
        }
        pointerMonitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.scrollWheel]) { [weak self] event in
            MainActor.assumeIsolated { self?.samplePointer(region:region,event:event) }
        }
    }
    private func samplePointer(region:CaptureRegionSelector.Region,event:NSEvent? = nil) {
        guard phase == .recording,let archive else { return }
        let location=event?.cgEvent?.location ?? CGEvent(source:nil)?.location
        guard let location else { return }
        let display=CGDisplayBounds(region.displayID)
        let x=(location.x-display.minX-region.rect.minX)/region.rect.width
        let y=1-(location.y-display.minY-region.rect.minY)/region.rect.height
        var sample=CapturePointerSample()
        if (0...1).contains(x),(0...1).contains(y) {
            let left=event?.type == .leftMouseDown || CGEventSource.buttonState(.combinedSessionState,button:.left)
            let right=event?.type == .rightMouseDown || CGEventSource.buttonState(.combinedSessionState,button:.right)
            sample=CapturePointerSample(x:x,y:y,buttons:(left ? 1 : 0)|(right ? 2 : 0),scroll:event?.type == .scrollWheel ? event?.scrollingDeltaY ?? 0 : 0)
        }
        archive.recordPointer(sample,at:recordingClock())
    }
    private func endPointerTracking() {
        pointerTimer?.invalidate();pointerTimer=nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) };pointerMonitor=nil
    }
    func cancelRendering() { renderTask?.cancel() }
    func renderNormalPreview(preserveTrim:Bool = false) async {
        guard let normalSource,let draft else { return }
        let selectedStart=trimStart,selectedEnd=trimEnd
        phase = .rendering;renderProgress=0;player?.pause()
        let edits=normalEdits,url=store.movie(draft.id)
        var options=CaptureMovieExport.Options();options.fps=min(24,normalSource.header.fps);options.maxDimension=1280
        // 5/16/24 are supported; preserve a 30/60 FPS source for the full-resolution export.
        renderTask=Task { [weak self] in
            guard let self else { return }
            do {
                try await CaptureNormalExport.export(source:normalSource,to:url,edits:edits,options:options) { [weak self] progress in
                    Task { @MainActor in self?.renderProgress=progress }
                }
                await self.preview(url)
                if preserveTrim,selectedEnd > selectedStart,selectedEnd <= self.duration+0.001 {
                    self.trimStart=selectedStart;self.trimEnd=min(selectedEnd,self.duration)
                }
            } catch is CancellationError { self.phase=self.player == nil ? .ready : .preview }
            catch { self.issue=tr(error.localizedDescription);self.phase = .failed }
        }
        await renderTask?.value;renderTask=nil
    }
    func applyNormalEdits() {
        guard !active,!exporting,let normalSource else { return }
        do { try normalEdits.save(to:normalSource.root);Task { await renderNormalPreview(preserveTrim:true) } }
        catch { issue=tr(error.localizedDescription) }
    }
    func editNormalAnnotations() {
        guard !active,!exporting,let normalSource else { return }
        do {
            var base=CaptureNormalEdits();base.showCursor=false;base.showClicks=false
            let renderer=try CaptureNormalRenderer(source:normalSource,edits:base)
            let image=try renderer.image(at:min(trimStart,normalSource.duration))
            let editor=CaptureNormalOverlayWindow(image:image,annotations:normalEdits.annotations,duration:normalSource.duration) { [weak self] annotations in
                self?.normalEdits.annotations=annotations;self?.applyNormalEdits()
            }
            overlayWindow=editor;editor.showWindow(nil)
        } catch { issue=tr(error.localizedDescription) }
    }
    func export() {
        guard !exporting, let source, let window else { return }
        NSApp.activate(ignoringOtherApps:true); window.makeKeyAndOrderFront(nil)
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:format.fileExtension) ?? .data]
        pendingSavePanel = panel
        panel.canCreateDirectories = true; panel.isExtensionHidden = false
        panel.nameFieldStringValue = "Thermo-recording."+format.fileExtension
        var options = CaptureMovieExport.Options(); options.format = format; options.start = trimStart; options.end = trimEnd; options.speed = speed; options.fps = animationFPS; options.maxDimension = animationSize
        let normal=normalSource,edits=normalEdits
        if let normal {
            options.fps=format == .mp4 ? normal.header.fps : animationFPS
            options.maxDimension=format == .mp4 ? 4096 : animationSize
        }
        exporting = true; issue = nil; savedURL = nil
        exportTask=Task {
            defer { exporting = false;exportTask=nil }
            let response = await withCheckedContinuation { continuation in panel.beginSheetModal(for:window) { continuation.resume(returning:$0) } }
            guard response == .OK, let url = panel.url else { return }
            do {
                if let normal { try edits.save(to:normal.root);try await CaptureNormalExport.export(source:normal,to:url,edits:edits,options:options) }
                else { try await CaptureMovieExport.export(source:source,to:url,options:options) }
                savedURL = url
            }
            catch { if !Task.isCancelled { issue = tr(error.localizedDescription) } }
        }
    }
    func cancelExport() {
        if let pendingSavePanel,pendingSavePanel.isVisible { pendingSavePanel.cancel(nil) }
        exportTask?.cancel()
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
        ScrollView {
        VStack(alignment:.leading,spacing:12) {
            if !hasRegion && model.player == nil && model.drafts.isEmpty && model.normalSource == nil { Text(tr("No recording drafts yet.")).foregroundStyle(.secondary); Spacer() }
            if model.phase == .rendering {
                ProgressView(value:model.renderProgress)
                HStack { Text(tr("Rendering preview…"));Spacer();Button(tr("Cancel rendering")) { model.cancelRendering() } }
            }
            if model.normalSource != nil,model.player == nil,!model.active {
                Button(tr("Generate preview from saved source")) { Task { await model.renderNormalPreview() } }
            }
            if model.normalSource != nil { CaptureNormalSettings(model:model) }
            if let player = model.player {
                RecordingPlayer(player:player).frame(height:240)
                HStack {
                    Button(tr("Play from trim start")) { model.playPreview() }
                    Button(tr("Pause")) { model.player?.pause() }
                }
                HStack {
                    Text(tr("Trim start")); TextField("",value:$model.trimStart,format:.number).frame(width:70)
                    Text(tr("Trim end")); TextField("",value:$model.trimEnd,format:.number).frame(width:70)
                    Picker(tr("Speed"),selection:$model.speed) { ForEach([0.25,0.5,1,1.5,2,4],id:\.self) { Text(String(format:"%g×",$0)).tag($0) } }.frame(width:140)
                }.textFieldStyle(.roundedBorder).disabled(model.active || model.exporting)
                HStack {
                    Picker(tr("Format"),selection:$model.format) { ForEach(CaptureMovieFormat.allCases,id:\.self) { Text($0.rawValue.uppercased()).tag($0) } }
                    Button(tr("Export recording…")) { model.export() }.disabled(model.active || model.exporting || !model.normalEdits.valid || model.trimStart < 0 || model.trimEnd <= model.trimStart || model.trimEnd > model.duration)
                    if model.exporting { ProgressView().controlSize(.small) }
                }.disabled(model.exporting)
                if model.exporting { Button(tr("Cancel export")) { model.cancelExport() } }
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
                Picker(tr("Recording mode"),selection:$model.mode) {
                    Text(tr("Quick recording")).tag(CaptureRecordingDraft.Mode.quick)
                    Text(tr("Ordinary recording (editable source)")).tag(CaptureRecordingDraft.Mode.normal)
                }.disabled(model.active)
                Text(tr(model.mode == .normal ? "Ordinary recording retains image frames and mouse actions for editing after recording." : "Quick recording · MP4 source")).font(.callout)
                HStack {
                    Picker(tr("Frame rate"),selection:$model.fps) { ForEach([5,16,24,30,60],id:\.self) { Text("\($0) FPS").tag($0) } }
                    Picker(tr("Quality"),selection:$model.quality) { ForEach(CaptureRecordingModel.Quality.allCases,id:\.self) { Text(tr(model.mode == .normal && $0 == .high ? "Original (PNG)" : $0.rawValue.capitalized)).tag($0) } }
                }.disabled(model.active)
                HStack {
                    Toggle(tr("System audio"),isOn:$model.systemAudio)
                    Toggle(tr("Show cursor"),isOn:$model.showsCursor)
                    Picker(tr("Start delay"),selection:$model.delay) { ForEach([0,3,5],id:\.self) { Text("\($0) s").tag($0) } }.frame(width:150)
                }.disabled(model.active)
                if model.mode == .normal {
                    Toggle(tr("Record keyboard overlay"),isOn:$model.recordKeyboard).disabled(model.active)
                    if model.recordKeyboard {
                        Picker(tr("Keys to record"),selection:$model.keyboardMode) {
                            Text(tr("Shortcuts only")).tag(CaptureKeyMode.shortcuts)
                            Text(tr("All keys (includes typed characters)")).tag(CaptureKeyMode.all)
                        }.disabled(model.active)
                        Text(tr("Input Monitoring is requested when recording starts. Secure Input is excluded.")).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Toggle(tr("Camera layer"),isOn:$model.captureCamera).onChange(of:model.captureCamera) { _ in model.refreshCaptureDevices() }
                        Toggle(tr("Microphone track"),isOn:$model.captureMicrophone).onChange(of:model.captureMicrophone) { _ in model.refreshCaptureDevices() }
                    }.disabled(model.active)
                    if model.captureCamera {
                        Picker(tr("Camera"),selection:$model.cameraID) { Text(tr("System default")).tag("");ForEach(model.cameraDevices) { Text($0.name).tag($0.id) } }.disabled(model.active)
                    }
                    if model.captureMicrophone {
                        Picker(tr("Microphone"),selection:$model.microphoneID) { Text(tr("System default")).tag("");ForEach(model.microphoneDevices) { Text($0.name).tag($0.id) } }.disabled(model.active)
                    }
                }
                if let session=model.devicePreview { CaptureDevicePreview(session:session).frame(width:180,height:120) }
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
            if model.phase == .failed,let draft=model.currentDraft { Button(tr("Discard current draft")) { model.discard(draft) } }
            if let url = model.savedURL { Text(tr("Saved to %@",url.path)).font(.caption).textSelection(.enabled) }
            Text(tr("Drafts stay on this Mac until you discard them. Exported files are separate.")).font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(minWidth:600,minHeight:400)
        }.frame(minWidth:600,minHeight:400)
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
