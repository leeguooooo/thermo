import AppKit
import SwiftUI
import ThermoL10n

extension FocusTimerModel {
    static let shared = FocusTimerModel(screen: NativeFocusBreakScreen())
}

extension FocusPhase {
    var title: String {
        switch self {
        case .idle: return tr("Timer is idle")
        case .focus: return tr("Focusing")
        case .postponed: return tr("Break postponed")
        case .rest(.short): return tr("Short break")
        case .rest(.long): return tr("Long break")
        case .breakFinished: return tr("Break finished")
        }
    }
}

extension FocusAction {
    var title: String {
        switch self {
        case .startFocus: return tr("Start focus")
        case .stopFocus: return tr("Stop focus")
        case .shortBreak: return tr("Start short break")
        case .longBreak: return tr("Start long break")
        case .breakNow: return tr("Start break now")
        case .postpone: return tr("Postpone 1 minute")
        case .stopBreak: return tr("Stop break")
        case .endBreakAndFocus: return tr("End break and start focus")
        case .dismissBreak: return tr("Close")
        }
    }
}

private final class FocusBreakWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// 不用清洁屏幕的辅助功能事件拦截：休息必须随时可退出，也不该因失焦或换屏就自行结束。
/// 覆盖每块屏幕的窗口挡住其他应用的鼠标操作，禁止切换应用挡住普通键盘操作。
@MainActor final class NativeFocusBreakScreen: FocusBreakScreen {
    private var windows: [NSWindow] = []
    private var screenObserver: NSObjectProtocol?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var previousOptions: NSApplication.PresentationOptions = []
    private var previousPolicy: NSApplication.ActivationPolicy?
    private weak var model: FocusTimerModel?

    func show(_ model: FocusTimerModel) {
        self.model = model
        guard windows.isEmpty else { return }
        previousOptions = NSApp.presentationOptions
        // 有 Dock 图标（.regular）时，窗口进不了其他应用的全屏空间；休息期间临时切成 .accessory，结束后还原。
        if NSApp.activationPolicy() == .regular { previousPolicy = .regular; NSApp.setActivationPolicy(.accessory) }
        present()
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            // 接上或拔掉显示器时重铺，保证每块当前连接的屏幕都被覆盖。
            MainActor.assumeIsolated { self?.closeWindows(); self?.present() }
        }
        // 禁止切换应用并不总能挡住 Cmd+Tab、调度中心或切换空间；一旦别的应用被激活或空间变了，就把休息画面拉回最前。
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification] {
            workspaceObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier { return }
                MainActor.assumeIsolated { self?.bringToFront() }
            })
        }
    }

    func hide() {
        guard !windows.isEmpty else { return }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        for observer in workspaceObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        workspaceObservers = []
        closeWindows()
        NSApp.presentationOptions = previousOptions
        if let previousPolicy { NSApp.setActivationPolicy(previousPolicy) }
        previousPolicy = nil
    }

    private func bringToFront() {
        guard !windows.isEmpty else { return }
        for window in windows { window.orderFrontRegardless() }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
    }

    private func present() {
        guard let model else { return }
        for screen in NSScreen.screens {
            let window = FocusBreakWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.backgroundColor = .black; window.isOpaque = true
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let wallpaper = NSWorkspace.shared.desktopImageURL(for: screen).flatMap(NSImage.init(contentsOf:))
            window.contentView = NSHostingView(rootView: FocusBreakOverlay(model: model, wallpaper: wallpaper))
            window.setFrame(screen.frame, display: false)
            windows.append(window); window.orderFrontRegardless()
        }
        NSApp.activate(ignoringOtherApps: true)
        windows.first?.makeKeyAndOrderFront(nil)
        // 隐藏菜单栏要求同时隐藏 Dock；不禁止强制退出，避免用户被困住。
        NSApp.presentationOptions = [.hideDock, .hideMenuBar, .disableProcessSwitching, .disableHideApplication]
    }

    private func closeWindows() {
        let old = windows; windows = []
        for window in old { window.close() }
    }
}

struct FocusBreakOverlay: View {
    @ObservedObject var model: FocusTimerModel
    let wallpaper: NSImage?
    var body: some View {
        ZStack {
            Color.black
            if let wallpaper { Image(nsImage: wallpaper).resizable().scaledToFill() }
            Color.black.opacity(0.4)
            VStack(spacing: 28) {
                VStack(spacing: 20) {
                    Text(model.phase.title).font(.system(size: 28, weight: .semibold))
                    if model.phase != .breakFinished {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            Text(FocusTimerModel.countdownText(model.remaining(at: context.date) ?? 0))
                                .font(.system(size: 96, weight: .light, design: .rounded)).monospacedDigit()
                        }
                    }
                    Text(model.phase == .breakFinished ? tr("Start the next focus when you're ready.") : tr("Step away from the screen and rest your eyes."))
                        .font(Theme.body)
                }
                .shadow(color: .black.opacity(0.5), radius: 8)
                HStack(spacing: 12) {
                    ForEach(FocusAction.available(in: model.phase), id: \.self) { action in
                        Button(action.title) { action.run(model) }.buttonStyle(FocusBreakButtonStyle())
                    }
                }
            }
            .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
    }
}

/// 休息画面压在任意壁纸上：用深色半透明底保证白字在浅色壁纸上也看得清，又不像系统白按钮那样跳出来。
private struct FocusBreakButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { BreakButton(configuration: configuration) }

    private struct BreakButton: View {
        let configuration: Configuration
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hover = false

        var body: some View {
            configuration.label
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 20).frame(minHeight: 38)
                .background(Capsule().fill(Color.black.opacity(configuration.isPressed ? 0.55 : hover ? 0.44 : 0.3)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(hover ? 0.42 : 0.26)))
                .contentShape(Capsule())
                .onHover { hover = $0 }
                .animation(reduceMotion ? nil : Theme.quick, value: hover)
                .animation(reduceMotion ? nil : Theme.quick, value: configuration.isPressed)
        }
    }
}
