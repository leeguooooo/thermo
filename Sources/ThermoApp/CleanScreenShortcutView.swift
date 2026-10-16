import AppKit
import SwiftUI
import ThermoL10n

struct CleanScreenShortcutControls: View {
    @ObservedObject var model: CleanScreenShortcutModel
    var body: some View {
        VStack(alignment:.leading,spacing:8) {
            Text(tr("Global Clean Screen shortcut")).font(.callout.weight(.semibold))
            HStack {
                ShortcutRecorder(model:model).frame(height:30)
                Button(tr("Remove shortcut")) { model.apply(nil) }.disabled(model.uncertain || (model.binding == nil && model.issue == nil))
            }
            Text(tr("Optional. The shortcut starts or ends Clean Screen from any app. Hold Esc for 3 seconds to exit even without a shortcut."))
                .font(.caption).foregroundStyle(.secondary)
            if let issue=model.issue { Text(issue).font(.caption).foregroundStyle(.orange) }
        }
    }
}

private struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var model: CleanScreenShortcutModel
    func makeNSView(context: Context) -> RecorderButton { let button=RecorderButton();button.model=model;return button }
    func updateNSView(_ button: RecorderButton, context: Context) {
        button.model=model
        button.title = model.recordingOwner == button.owner ? tr("Press a shortcut; Esc cancels") : model.binding?.label ?? tr("Record shortcut…")
        button.isEnabled = !model.uncertain
        button.setAccessibilityLabel(tr("Record global Clean Screen shortcut"))
    }
    final class RecorderButton: NSButton {
        let owner=UUID()
        weak var model: CleanScreenShortcutModel?
        override var acceptsFirstResponder: Bool { true }
        init() { super.init(frame:.zero);bezelStyle = .rounded;target=self;action=#selector(beginRecording) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        @objc private func beginRecording() { model?.beginRecording(owner);window?.makeFirstResponder(self) }
        override func resignFirstResponder() -> Bool { model?.cancelRecording(owner);return super.resignFirstResponder() }
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if model?.recordingOwner == owner,event.type == .keyDown { keyDown(with:event);return true }
            return super.performKeyEquivalent(with:event)
        }
        override func keyDown(with event: NSEvent) {
            guard let model,model.recordingOwner == owner else { super.keyDown(with:event);return }
            if event.keyCode == 53 { model.cancelRecording(owner) }
            else if event.keyCode == 51,CleanScreenKeyBinding.flags(event.modifierFlags) == 0 { model.cancelRecording(owner);model.apply(nil) }
            else { model.record(.captured(event),owner:owner) }
        }
    }
}

@MainActor enum CleanScreenSetupWindow {
    private final class State: NSObject, NSWindowDelegate {
        var window: NSWindow?
        func windowWillClose(_ notification: Notification) { window?.contentView=nil;window=nil }
    }
    private static let state=State()
    static func show() {
        if let window=state.window { NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil);return }
        let window=NSWindow(contentRect:.init(x:0,y:0,width:528,height:640),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.title=tr("Clean Screen");window.isReleasedWhenClosed=false;window.delegate=state
        window.contentView=NSHostingView(rootView:CleanScreenSetupView(model:.shared,close:{ close() }).preferredColorScheme(.dark))
        state.window=window;window.center();NSApp.activate(ignoringOtherApps:true);window.makeKeyAndOrderFront(nil)
    }
    static func close() { state.window?.close() }
}
