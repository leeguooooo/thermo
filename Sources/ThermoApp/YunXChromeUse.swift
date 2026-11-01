import AgentCore
import AppKit
import CleanKit
import Foundation
import SwiftUI
import ThermoL10n

/// chrome-use is how 云析下载 signs in. It is only ever installed from a click, by the project's own
/// installer; everything else in Thermo works without it.
@MainActor final class YunXChromeUseSetup: ObservableObject {
    enum State: Equatable { case checking, missing, notConnected, ready }
    struct Probe: Equatable {
        var tool: String?
        var connected = false
        var profile: String?
    }
    /// Runs one argv and hands over its output line by line; returns the exit status.
    typealias Run = @Sendable (String, [String], [String: String], @escaping @Sendable (String) -> Void) async -> Int32

    static let shared = YunXChromeUseSetup()
    static let installerURL = "https://raw.githubusercontent.com/leeguooooo/chrome-use/main/install.sh"
    static let extensionURL = "https://chromewebstore.google.com/detail/chrome-use/knfcmbamhjmaonkfnjhldjedeobeafmk"
    private static let dismissedKey = "yunx.chromeuse.cardDismissedVersion"

    @Published private(set) var state = State.checking
    @Published private(set) var working = false
    @Published private(set) var output: [String] = []
    @Published private(set) var failure: String?

    private let detect: @Sendable () -> Probe
    private let run: Run
    private let temporary: URL
    private let defaults: UserDefaults
    private var probe = Probe()
    private var launchCard: NSWindow?

    init(detect: @escaping @Sendable () -> Probe = YunXChromeUseSetup.liveDetect, run: @escaping Run = YunXChromeUseSetup.liveRun,
         temporary: URL = FileManager.default.temporaryDirectory, defaults: UserDefaults = .standard) {
        self.detect = detect
        self.run = run
        self.temporary = temporary
        self.defaults = defaults
    }

    nonisolated static func liveDetect() -> Probe {
        guard let tool = ChromeInspector.chromeUseDiagTool() else { return Probe() }
        let result = CommandRunner.run(tool, arguments: ["browsers", "--json"], timeout: 20, captureError: false)
        let found = YunXChromeCookies.connection(result.output)
        return Probe(tool: tool, connected: result.status == 0 && found.connected, profile: found.profile)
    }

    nonisolated static func liveRun(_ tool: String, _ args: [String], _ env: [String: String], _ line: @escaping @Sendable (String) -> Void) async -> Int32 {
        await withCheckedContinuation { done in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = args
            // A GUI app inherits a minimal PATH.
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:" + NSHomeDirectory() + "/.local/bin"
            process.environment = environment.merging(env) { _, new in new }
            process.standardInput = FileHandle.nullDevice
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { handle.readabilityHandler = nil; return }
                String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).forEach { line(String($0)) }
            }
            process.terminationHandler = { done.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                line(error.localizedDescription)
                done.resume(returning: -1)
            }
        }
    }

    func refresh() async {
        let detect = self.detect
        let found = await Task.detached { detect() }.value
        probe = found
        state = found.tool == nil ? .missing : found.connected ? .ready : .notConnected
    }

    private func step(_ tool: String, _ args: [String], env: [String: String] = [:]) async -> Bool {
        let box = LineBox()
        let status = await run(tool, args, env) { text in
            box.add(text)
            Task { @MainActor [weak self] in self?.output.append(contentsOf: box.take()) }
        }
        output.append(contentsOf: box.take())
        if status != 0 { failure = tr("The step failed (exit code %1$@). See the output below.", String(status)) }
        return status == 0
    }

    /// The button: fetches the official installer, runs it, registers the Chrome bridge, checks again.
    func install() async {
        guard !working else { return }
        working = true
        failure = nil
        output = []
        defer { working = false }
        let script = temporary.appendingPathComponent("chrome-use-install-\(UUID().uuidString).sh")
        defer { try? FileManager.default.removeItem(at: script) }
        guard await step("/usr/bin/curl", ["-fsSL", "--retry", "2", "-o", script.path, Self.installerURL]) else { return }
        // Thermo needs the CLI, not a skill written into the user's agent folders.
        guard await step("/bin/sh", [script.path], env: ["AGENT_BROWSER_NO_SKILL": "1", "AGENT_BROWSER_NO_SETUP": "1"]) else { return }
        await refresh()
        guard let tool = probe.tool else {
            failure = tr("The installer finished, but chrome-use was not found.")
            return
        }
        guard !probe.connected else { return }
        _ = await step(tool, ["extension", "install", "--no-open"])
    }

    /// Registers the bridge, then lets chrome-use open the store page or a window in that profile.
    func connect() async {
        guard !working, let tool = probe.tool else { return }
        working = true
        failure = nil
        output = []
        defer { working = false }
        guard await step(tool, ["extension", "install", "--no-open"]) else { return }
        var args = ["connect"]
        if let profile = probe.profile { args += ["--browser", profile, "--wait", "120"] }
        _ = await step(tool, args)
        await refresh()
    }

    // MARK: First launch after an update

    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

    func offerOnLaunch() async {
        guard defaults.string(forKey: Self.dismissedKey) != version else { return }
        await refresh()
        guard state != .ready else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 240), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: true)
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: YunXChromeUseLaunchCard(setup: self) { [weak self] in self?.dismissLaunchCard() }.preferredColorScheme(.dark))
        window.center()
        window.delegate = closeWatcher
        launchCard = window
        window.makeKeyAndOrderFront(nil)
    }

    private lazy var closeWatcher = CloseWatcher { [weak self] in self?.dismissLaunchCard() }

    func dismissLaunchCard() {
        defaults.set(version, forKey: Self.dismissedKey)
        launchCard?.delegate = nil
        launchCard?.close()
        launchCard = nil
    }

    private final class CloseWatcher: NSObject, NSWindowDelegate {
        let closed: @MainActor () -> Void
        init(closed: @escaping @MainActor () -> Void) { self.closed = closed }
        func windowWillClose(_ notification: Notification) { MainActor.assumeIsolated { closed() } }
    }
}

private final class LineBox: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func add(_ line: String) { lock.withLock { lines.append(line) } }
    func take() -> [String] { lock.withLock { defer { lines = [] }; return lines } }
}

/// One step at a time: install, connect, and what went wrong.
struct YunXChromeUseCard: View {
    @ObservedObject var setup: YunXChromeUseSetup

    var body: some View {
        InspectorPanel {
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                HStack(spacing: Theme.Space.m) {
                    Image(systemName: "globe").font(.system(size: 18)).foregroundStyle(Theme.accent).frame(width: 32, height: 32)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.accent.opacity(0.14)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                        Text(detail).font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: Theme.Space.m)
                    if setup.working { ProgressView().controlSize(.small) }
                    action
                }
                if let failure = setup.failure {
                    Text(failure).font(Theme.secondary).foregroundStyle(Theme.danger).textSelection(.enabled)
                }
                if !setup.output.isEmpty {
                    ScrollView {
                        Text(setup.output.suffix(40).joined(separator: "\n")).font(Theme.mono).foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 96)
                }
            }.padding(Theme.Space.l)
        }
    }

    private var title: String {
        setup.state == .notConnected ? tr("Connect chrome-use to Chrome") : tr("YunX Download needs chrome-use")
    }

    private var detail: String {
        setup.state == .notConnected
            ? tr("Open Chrome, then connect. If the extension is missing, click Add to Chrome on the page that opens.")
            : tr("Sign-ins come from your own Chrome through chrome-use. Other Thermo features work without it.")
    }

    @ViewBuilder private var action: some View {
        switch setup.state {
        case .missing:
            Button(tr("Install chrome-use")) { Task { await setup.install() } }
                .buttonStyle(PillButtonStyle(prominent: true)).disabled(setup.working)
        case .notConnected:
            Button(tr("Connect Chrome")) { Task { await setup.connect() } }
                .buttonStyle(PillButtonStyle(prominent: true)).disabled(setup.working)
        case .checking, .ready: EmptyView()
        }
    }
}

/// Shown once per version; the 云析下载 page keeps offering the same card.
struct YunXChromeUseLaunchCard: View {
    @ObservedObject var setup: YunXChromeUseSetup
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            YunXChromeUseCard(setup: setup)
            HStack {
                Spacer()
                Button(setup.state == .ready ? tr("Done") : tr("Later"), action: dismiss).buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, Theme.Space.xl).padding(.top, 36).padding(.bottom, Theme.Space.l)
        .frame(width: 460, alignment: .topLeading)
        .background(Theme.canvas)
    }
}
