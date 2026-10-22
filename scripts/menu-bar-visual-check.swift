// Isolated, operator-driven macOS 27 visibility acceptance. Compiled by
// verify-menu-bar.py; never linked into the shipped application.
import AppKit
import CMenuBar
import MenuBarCore

@MainActor private final class VisualCheckSession: MenuBarVisibilitySession {
    private let handle: TMMenuBarSession
    init(_ configuration: MenuBarConfiguration) throws {
        handle = try TMMenuBarSession.make(allowedBundles: configuration.allowedBundles)
    }
    func activate(completion: @escaping @MainActor (String?) -> Void) {
        handle.activate { error in
            let message = error?.localizedDescription
            Task { @MainActor in completion(message) }
        }
    }
    func invalidate() -> String? {
        do { try handle.invalidate(); return nil } catch { return error.localizedDescription }
    }
}

@MainActor final class MenuBarVisualCheck: NSWindowController, NSWindowDelegate {
    private struct Fixture {
        let bundle: String
        let label: String
        let section: MenuBarSection
    }
    private let status = NSTextField(wrappingLabelWithString: "尚未开始。测试仅使用同目录的三个临时图标程序。")
    private var fixtures: [Fixture] = []
    private let realApps: Bool
    private var scopeStarted = false
    private var deadline: Task<Void, Never>?
    private var phase = "idle"
    private var trace: [[String: Any]] = []
    private var lastAllowedBundles: [String] = []
    private let hiddenBundle = Bundle.main.object(forInfoDictionaryKey: "ThermoMenuBarRealHiddenBundle") as? String ?? "com.tencent.xinWeChat419WechatUse"
    private let alwaysBundle = Bundle.main.object(forInfoDictionaryKey: "ThermoMenuBarRealAlwaysBundle") as? String ?? "com.bitwarden.desktop"
    private let own = Bundle.main.bundleIdentifier ?? ""
    private let root = Bundle.main.bundleURL.deletingLastPathComponent().resolvingSymlinksInPath()
    private lazy var controller: MenuBarSessionController = {
        let controller = MenuBarSessionController { try VisualCheckSession($0) }
        controller.didChange = { [weak self] state in
            guard let self else { return }
            let description: String
            switch state {
            case .visible: description = "已请求恢复全部图标"
            case .applying: description = "正在请求更改显示"
            case .applied: description = "macOS 已接受请求；请检查实际图标"
            case let .failed(error): description = "请求失败：" + error
            }
            self.status.stringValue = self.phase + " · " + description
            self.record(description)
        }
        return controller
    }()

    init(realApps: Bool = false) {
        self.realApps = realApps
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 340),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "菜单栏真实显示验收"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let stack = NSStackView()
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let title = NSTextField(labelWithString: realApps ? "Thermo 显示 · \(hiddenBundle) 隐藏 · \(alwaysBundle) 始终隐藏" : "MBV 显示 · MBH 隐藏 · MBA 始终隐藏")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let explanation = NSTextField(wrappingLabelWithString: realApps
            ? "仅临时改变这两个已运行应用的图标显示，其他应用保留在白名单。不会退出应用或改写分组。45 秒后自动请求恢复，也可随时按 Escape。"
            : "为避开系统溢出区，会话会暂时隐藏其他第三方菜单栏图标。应用继续运行，持久配置不变。45 秒后自动请求恢复，也可随时按 Escape。系统图标可能受私有接口影响。")
        explanation.font = .systemFont(ofSize: 13)
        stack.addArrangedSubview(title); stack.addArrangedSubview(explanation)
        let first = NSStackView(); first.spacing = 8
        for (text, selector) in [(realApps ? "1 开始实际应用对照" : "1 显示三个测试图标", #selector(beginVisualCheck)), ("2 收起分组", #selector(collapse)),
                                 ("3 展开隐藏组", #selector(showHidden)), (realApps ? "4 展开全部对照组" : "4 展开全部测试组", #selector(showAll))] {
            let button = NSButton(title: text, target: self, action: selector)
            first.addArrangedSubview(button)
        }
        stack.addArrangedSubview(first)
        let restore = NSButton(title: "5 结束测试并恢复所有图标", target: self, action: #selector(endTest))
        restore.keyEquivalent = "\u{1b}"
        stack.addArrangedSubview(restore)
        status.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        stack.addArrangedSubview(status)
        let note = NSTextField(wrappingLabelWithString:
            "回调、AX 节点或窗口坐标都不能代替图标画面。每一步均需观察菜单栏；本程序只记录请求，不自动宣称验收通过。")
        note.font = .systemFont(ofSize: 12); note.textColor = .secondaryLabelColor
        stack.addArrangedSubview(note)
        window.contentView!.addSubview(stack)
        if realApps { status.stringValue = "尚未开始。只操作上方列出的已运行对照应用。" }
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: window.contentView!.bottomAnchor, constant: -20)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() { window?.center(); window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    func windowWillClose(_ notification: Notification) { restore() }

    @objc private func beginVisualCheck() { apply(.all, phase: realApps ? "三个实际应用全部显示" : "三个测试图标全部显示") }
    @objc private func collapse() { apply(.collapsed, phase: realApps ? "两个对照应用应隐藏" : "仅 MBV 应显示") }
    @objc private func showHidden() { apply(.hidden, phase: realApps ? hiddenBundle + " 应显示，" + alwaysBundle + " 应隐藏" : "MBV 与 MBH 应显示") }
    @objc private func showAll() { apply(.all, phase: realApps ? "三个实际应用全部显示" : "MBV、MBH、MBA 应显示") }
    @objc private func endTest() { restore() }

    func restore() {
        deadline?.cancel(); deadline = nil
        scopeStarted = false; phase = "结束隔离会话"
        lastAllowedBundles = []
        controller.restore()
    }

    private func apply(_ reveal: MenuBarReveal, phase: String) {
        do {
            guard own.hasPrefix("dev.thermo.menubarqa."), TMMenuBarSession.isAvailable() else {
                throw NSError(domain: "MenuBarVisualCheck", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "不是隔离验收 App，或系统接口不可用。"])
            }
            fixtures = try loadFixtures()
            if !scopeStarted {
                scopeStarted = true
                deadline = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: 45_000_000_000) } catch { return }
                    self?.restore()
                }
            }
            self.phase = phase
            let systemBundles = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { $0.hasPrefix("com.apple.") }
            // Preserve the installed Thermo icon as a recovery/control item.
            let population = Set((realApps ? NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier) : systemBundles + fixtures.map(\.bundle)) + [own, "dev.thermo.app"])
            var sections = MenuBarSections()
            for fixture in fixtures { sections.assign(fixture.bundle, to: fixture.section) }
            // Keep a scoped background mask even for .all, so the three test
            // icons can be observed outside overflow. End Test removes it.
            let config = sections.configuration(running: population, ownBundle: own, reveal: reveal)
            lastAllowedBundles = config?.allowedBundles ?? []
            controller.apply(realApps ? config : config ?? MenuBarConfiguration(allowedBundles: population.sorted()))
        } catch {
            restore()
            status.stringValue = error.localizedDescription
            record("拒绝开始：" + error.localizedDescription)
        }
    }

    private func loadFixtures() throws -> [Fixture] {
        if realApps {
            return try [("dev.thermo.app", "Thermo", MenuBarSection.visible),
                        (hiddenBundle, hiddenBundle, MenuBarSection.hidden),
                        (alwaysBundle, alwaysBundle, MenuBarSection.alwaysHidden)].map { bundle, label, section in
                guard NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: { !$0.isTerminated }) else {
                    throw NSError(domain: "MenuBarVisualCheck", code: 3,
                                  userInfo: [NSLocalizedDescriptionKey: "对照应用未运行：" + label])
                }
                return Fixture(bundle: bundle, label: label, section: section)
            }
        }
        return try [("Thermo Menu Bar Visible Fixture.app", "MBV", MenuBarSection.visible),
             ("Thermo Menu Bar Fixture.app", "MBH", MenuBarSection.hidden),
             ("Thermo Menu Bar Always Fixture.app", "MBA", MenuBarSection.alwaysHidden)].map { name, label, section in
            let url = root.appendingPathComponent(name).resolvingSymlinksInPath()
            guard url.deletingLastPathComponent() == root, let bundle = Bundle(url: url)?.bundleIdentifier,
                  bundle.hasPrefix("org.example.mbfx."),
                  NSRunningApplication.runningApplications(withBundleIdentifier: bundle).contains(where: {
                      !$0.isTerminated && $0.bundleURL?.resolvingSymlinksInPath() == url
                  }) else {
                throw NSError(domain: "MenuBarVisualCheck", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "请先启动同目录的 " + name])
            }
            return Fixture(bundle: bundle, label: label, section: section)
        }
    }

    private func record(_ result: String) {
        trace.append(["time": Date().timeIntervalSince1970, "phase": phase, "result": result, "allowedBundles": lastAllowedBundles])
        let report: [String: Any] = ["events": trace, "pixelAcceptance": "not automatically asserted",
                                   "fixtureLabels": fixtures.map(\.label), "realApps": realApps, "watchdogSeconds": 45,
                                   "persistentAssignmentsChanged": false]
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("visual-check-requests.json"), options: .atomic)
        }
    }
}
