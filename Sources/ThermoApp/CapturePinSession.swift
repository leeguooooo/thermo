import AppKit
import CaptureCore
import SwiftUI
import ThermoL10n

@MainActor final class CapturePinSession:ObservableObject {
    @Published private(set) var library:CapturePinLibrary
    @Published var issue:String?
    private(set) var windows:[UUID:CaptureEditor]=[:]
    let store:CapturePinLibraryStore
    private var dirty:Set<UUID>=[]
    private var saving:Task<Void,Never>?
    private var removing:Set<UUID>=[]
    private var loadFailed=false
    var onCountChange:((Int)->Void)?
    private var libraryWindow:NSWindowController?
    var count:Int { library.pins.filter { $0.groupID == library.currentGroupID && $0.closedAt == nil }.count }
    init(store:CapturePinLibraryStore = .init()) {
        self.store=store
        do { library=try store.load(defaultName:tr("Default pin group")) }
        catch { library = .init(defaultName:tr("Default pin group"));issue=tr(error.localizedDescription);loadFailed=true }
    }
    func restoreWindows() {
        do { try checkLoaded();try prepareWindows(for:library.currentGroupID);displayCurrent() }
        catch { issue=tr(error.localizedDescription) }
    }
    private func checkLoaded() throws { if loadFailed { throw CapturePinFailure.invalidLibrary } }
    func retryLoad() {
        do {
            saving?.cancel();saving=nil
            let saved=try store.load(defaultName:tr("Default pin group"))
            let pins=saved.pins.filter { $0.groupID == saved.currentGroupID && $0.closedAt == nil }
            let documents=try pins.map { ($0,try store.snapshot(for:$0)) }
            for editor in Array(windows.values) { editor.close() }
            windows.removeAll();dirty.removeAll();library=saved;loadFailed=false;issue=nil
            for (pin,document) in documents { makeEditor(pin,document:document.document,content:document.content) };displayCurrent()
        } catch { loadFailed=true;issue=tr(error.localizedDescription) }
    }
    private func commit(_ next:CapturePinLibrary,documents:[UUID:CaptureDocument]=[:],contents:[UUID:CapturePinContent]=[:]) throws {
        try checkLoaded();let saved=try store.save(next,documents:documents,contents:contents);library=saved;onCountChange?(count)
    }
    func flush() throws {
        saving?.cancel();saving=nil;try checkLoaded()
        var next=library,documents:[UUID:CaptureDocument]=[:],contents:[UUID:CapturePinContent]=[:]
        for (id,editor) in windows {
            guard let index=next.pins.firstIndex(where: { $0.id == id }) else { continue }
            let model=editor.model
            guard model.pinContentSaveError == nil else { throw CapturePinFailure.invalidContent }
            next.pins[index].frame=editor.window?.frame ?? .zero
            next.pins[index].opacity=model.opacity;next.pins[index].zoom=model.zoom;next.pins[index].pan=model.pan
            next.pins[index].pinned=model.pinned;next.pins[index].locked=model.locked;next.pins[index].shadow=model.shadow;next.pins[index].title=model.pinTitle
            if dirty.contains(id) { next.pins[index].snapshotID=UUID();documents[id]=model.document;contents[id]=model.pinContent;next.pins[index].contentKind=model.pinContent?.kind }
        }
        try commit(next,documents:documents,contents:contents);dirty.removeAll();issue=nil
    }
    private func changed(_ id:UUID,document:Bool) {
        if document { dirty.insert(id) }
        saving?.cancel()
        saving=Task { [weak self] in
            do { try await Task.sleep(nanoseconds:350_000_000);try Task.checkCancellation();try self?.flush() }
            catch is CancellationError {} catch { self?.issue=tr(error.localizedDescription) }
        }
    }
    @discardableResult func open(_ image:CGImage,content:CapturePinContent? = nil) throws -> UUID {
        try flush()
        var next=library
        for index in next.pins.indices where next.pins[index].groupID == next.currentGroupID { next.pins[index].hidden=false }
        var pin=CaptureSavedPin(groupID:next.currentGroupID);pin.contentKind=content?.kind;next.pins.append(pin)
        let doc=CaptureDocument(image:image);try commit(next,documents:[pin.id:doc],contents:content.map { [pin.id:$0] } ?? [:]);makeEditor(pin,document:doc,content:content);displayCurrent();return pin.id
    }
    @discardableResult func open(_ content:CapturePinContent) throws -> UUID { try open(content.previewImage(),content:content) }
    private func makeEditor(_ pin:CaptureSavedPin,document:CaptureDocument,content:CapturePinContent? = nil) {
        let editor=CaptureEditor(image:document.image,onClose:{ [weak self] in self?.windows.removeValue(forKey:pin.id) },shouldClose:{ [weak self] in self?.willClose(pin.id) ?? true })
        let model=editor.model;model.document=document;model.pinContent=content;model.opacity=pin.opacity;model.zoom=pin.zoom;model.pan=pin.pan;model.pinned=pin.pinned;model.locked=pin.locked;model.shadow=pin.shadow;model.pinTitle=pin.title
        model.makeImageCopy={ [weak self] image in do { try self?.open(image) } catch { self?.issue=tr(error.localizedDescription);self?.showLibrary() } }
        model.showPinLibrary={ [weak self] in self?.showLibrary() }
        model.onMutation={ [weak self] document in self?.changed(pin.id,document:document) }
        editor.onWindowChange={ [weak self] in self?.changed(pin.id,document:false) }
        if let window=editor.window {
            if pin.frame.width >= 600,pin.frame.height >= 360 { window.setFrame(pin.frame,display:false) }
            ensureVisible(window);model.changeWindow?()
        }
        windows[pin.id]=editor
    }
    private func prepareWindows(for group:UUID,in value:CapturePinLibrary? = nil) throws {
        // Decode all missing documents first; a damaged member cannot cause a partial switch.
        let missing=(value ?? library).pins.filter { $0.groupID == group && $0.closedAt == nil && windows[$0.id] == nil }
        let docs=try missing.map { ($0,try store.snapshot(for:$0)) }
        for (pin,doc) in docs { makeEditor(pin,document:doc.document,content:doc.content) }
    }
    private func displayCurrent() {
        for pin in library.pins {
            if pin.groupID == library.currentGroupID && pin.closedAt == nil && !pin.hidden { windows[pin.id]?.showWindow(nil) }
            else { windows[pin.id]?.window?.orderOut(nil) }
        }
        onCountChange?(count)
    }
    private func willClose(_ id:UUID) -> Bool {
        guard !removing.contains(id) else { return true }
        do {
            try flush();var next=library
            guard let index=next.pins.firstIndex(where:{ $0.id == id }) else { return true }
            next.pins[index].closedAt=Date();next.pruneHistory();try commit(next);return true
        } catch { issue=tr(error.localizedDescription);showLibrary();return false }
    }
    func showPin(_ id:UUID) throws {
        guard let pin=library.pins.first(where:{ $0.id == id }) else { throw CapturePinFailure.missingPin }
        try switchGroup(pin.groupID)
        if pin.closedAt != nil { try restore(id) }
        else {
            var next=library;next.pins[next.pins.firstIndex { $0.id == id }!].hidden=false;try commit(next);displayCurrent()
        }
        windows[id]?.window?.makeKeyAndOrderFront(nil)
    }
    func restore(_ id:UUID? = nil) throws {
        try flush()
        let pin=library.pins.filter { $0.groupID == library.currentGroupID && $0.closedAt != nil && (id == nil || $0.id == id) }.sorted { $0.closedAt! > $1.closedAt! }.first
        guard var pin else { return }
        let doc=try store.snapshot(for:pin);pin.closedAt=nil;pin.hidden=false
        var next=library;next.pins[next.pins.firstIndex { $0.id == pin.id }!]=pin;try commit(next);makeEditor(pin,document:doc.document,content:doc.content);displayCurrent();windows[pin.id]?.window?.makeKeyAndOrderFront(nil)
    }
    func switchGroup(_ id:UUID) throws {
        guard library.groups.contains(where:{ $0.id == id }) else { throw CapturePinFailure.invalidLibrary }
        try flush();try prepareWindows(for:id)
        var next=library;next.currentGroupID=id;try commit(next);displayCurrent()
    }
    @discardableResult func createGroup(name:String,color:String? = nil,switchTo:Bool=true) throws -> UUID {
        try flush();let group=CapturePinGroup(name:name.trimmingCharacters(in:.whitespacesAndNewlines),color:color)
        var next=library;next.groups.append(group);if switchTo { next.currentGroupID=group.id }
        guard next.valid else { throw CapturePinFailure.invalidName };try commit(next);displayCurrent();return group.id
    }
    func updateGroup(_ id:UUID,name:String,color:String?) throws {
        try flush();var next=library;guard let index=next.groups.firstIndex(where:{ $0.id == id }) else { return }
        next.groups[index].name=name.trimmingCharacters(in:.whitespacesAndNewlines);next.groups[index].color=color
        guard next.valid else { throw CapturePinFailure.invalidName };try commit(next);displayCurrent()
    }
    func reorderGroup(_ id:UUID,offset:Int) throws {
        try flush();var next=library;guard let index=next.groups.firstIndex(where:{ $0.id == id }),next.groups.indices.contains(index+offset) else { return }
        next.groups.swapAt(index,index+offset);try commit(next)
    }
    func movePin(_ id:UUID,to group:UUID) throws {
        try flush();var next=library
        guard let index=next.pins.firstIndex(where:{ $0.id == id }),next.groups.contains(where:{ $0.id == group }) else { throw CapturePinFailure.missingPin }
        next.pins[index].groupID=group;try prepareWindows(for:next.currentGroupID,in:next);try commit(next);displayCurrent()
    }
    func removeGroup(_ id:UUID,movingTo destination:UUID?) throws {
        try flush();guard library.groups.count > 1 else { throw CapturePinFailure.invalidLibrary }
        var next=library
        if let destination {
            guard destination != id,next.groups.contains(where:{ $0.id == destination }) else { throw CapturePinFailure.invalidLibrary }
            for i in next.pins.indices where next.pins[i].groupID == id { next.pins[i].groupID=destination }
        } else { next.pins.removeAll { $0.groupID == id } }
        next.groups.removeAll { $0.id == id }
        if next.currentGroupID == id { next.currentGroupID=destination ?? next.groups[0].id }
        try prepareWindows(for:next.currentGroupID,in:next);try commit(next);discardRemovedWindows();displayCurrent()
    }
    func clearGroup(_ id:UUID) throws {
        try flush();var next=library;next.pins.removeAll { $0.groupID == id };try commit(next);discardRemovedWindows();displayCurrent()
    }
    func destroyPin(_ id:UUID) throws {
        try flush();var next=library;next.pins.removeAll { $0.id == id };try commit(next);discardRemovedWindows();displayCurrent()
    }
    private func discardRemovedWindows() {
        for id in Array(windows.keys) where !library.pins.contains(where:{ $0.id == id }) {
            removing.insert(id);windows[id]?.close();windows.removeValue(forKey:id);dirty.remove(id);removing.remove(id)
        }
    }
    func setAllHidden(_ hidden:Bool) throws {
        try flush();var next=library
        for i in next.pins.indices where next.pins[i].groupID == next.currentGroupID && next.pins[i].closedAt == nil { next.pins[i].hidden=hidden }
        try commit(next);displayCurrent()
    }
    func closeAll() { for pin in library.pins where pin.groupID == library.currentGroupID && pin.closedAt == nil { windows[pin.id]?.window?.performClose(nil) } }
    func setHistoryLimit(_ value:Int) throws { try flush();var next=library;next.historyLimit=value;next.pruneHistory();try commit(next);discardRemovedWindows() }
    func ensureAllVisible() { for editor in windows.values { if let window=editor.window { ensureVisible(window) } };do { try flush() } catch { issue=tr(error.localizedDescription) } }
    private func ensureVisible(_ window:NSWindow) {
        let screens=NSScreen.screens.map(\.visibleFrame)
        guard !screens.contains(where:{ $0.intersection(window.frame).width >= 100 && $0.intersection(window.frame).height >= 40 }),let screen=NSScreen.main else { return }
        var frame=window.frame;frame.origin=CGPoint(x:screen.visibleFrame.midX-frame.width/2,y:screen.visibleFrame.midY-frame.height/2);window.setFrame(frame,display:false)
    }
    func showLibrary() {
        if libraryWindow == nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:800,height:560),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            window.title=tr("Pin groups and history");window.isReleasedWhenClosed=false;window.minSize=NSSize(width:720,height:440)
            window.contentView=NSHostingView(rootView:CapturePinLibraryView(session:self));window.center();libraryWindow=NSWindowController(window:window)
        }
        libraryWindow?.showWindow(nil)
    }
}
