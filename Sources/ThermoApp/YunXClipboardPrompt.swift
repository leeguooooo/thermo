import AppKit
import SwiftUI
import ThermoL10n

/// Watches the clipboard from launch. Holds no model: `YunXDownloadModel` and Gopeed start only on Open.
@MainActor final class YunXClipboardPrompt {
    static let shared = YunXClipboardPrompt()
    private static let pollInterval: TimeInterval = 1
    private static let visibleSeconds: TimeInterval = 10
    private static let size = NSSize(width: 400, height: 132)
    private static let margin: CGFloat = 24

    private final class Panel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { false }
    }
    /// Without this the first click on an inactive panel is swallowed.
    private final class Host: NSHostingView<YunXClipboardPromptView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private var timer: Timer?
    private var hideTimer: Timer?
    private var panel: Panel?
    private var current: YunXClipboardHit?
    private lazy var watcher = YunXClipboardWatcher(source: YunXSystemClipboard(), canPrompt: { [weak self] in
        self?.current == nil && MainWindow.window?.isKeyWindow != true
    }, present: { [weak self] in self?.show($0) })

    /// Starts or stops polling to match the setting. Disabled means no timer at all.
    func refresh() {
        guard YunXClipboardSetting.enabled() else {
            timer?.invalidate(); timer = nil
            dismiss()
            return
        }
        guard timer == nil else { return }
        watcher.rebaseline()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watcher.poll() }
        }
        timer.tolerance = 0.25
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func show(_ hit: YunXClipboardHit) {
        current = hit
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = Host(rootView: YunXClipboardPromptView(hit: hit, ignore: { [weak self] in self?.ignore() },
                                                                   open: { [weak self] in self?.open() }))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: visible.maxX - Self.size.width - Self.margin, y: visible.minY + Self.margin))
        }
        panel.orderFrontRegardless()
        hideTimer?.invalidate()
        let hide = Timer(timeInterval: Self.visibleSeconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }
        RunLoop.main.add(hide, forMode: .common)
        hideTimer = hide
    }

    private func makePanel() -> Panel {
        let panel = Panel(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: true)
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        return panel
    }

    private func dismiss() {
        hideTimer?.invalidate(); hideTimer = nil
        panel?.orderOut(nil)
        panel?.contentView = nil
        current = nil
    }

    private func ignore() {
        if let current { watcher.ignore(current.link) }
        dismiss()
    }

    private func open() {
        guard let hit = current else { return }
        dismiss()
        MainWindow.show(.yunx)
        Task { await YunXDownloadModel.shared.openCopied(hit.link, passcode: hit.passcode) }
    }
}

struct YunXClipboardPromptView: View {
    let hit: YunXClipboardHit
    let ignore: () -> Void
    let open: () -> Void

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: hit.symbol).frame(width: 36, height: 36)
                    .background(Circle().fill(Color.accentColor.opacity(0.18)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.title).font(.callout.weight(.medium)).lineLimit(1)
                    Text(hit.link).font(.caption).foregroundStyle(Theme.textSecondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 0)
                Button(action: ignore) { Image(systemName: "xmark") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .accessibilityLabel(tr("Close"))
            }
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(tr("Ignore"), action: ignore).buttonStyle(PillButtonStyle())
                Button(tr("Open"), action: open).buttonStyle(PillButtonStyle(prominent: true))
            }
        }
        .padding(Theme.Space.m)
        .frame(width: 400, height: 132)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
