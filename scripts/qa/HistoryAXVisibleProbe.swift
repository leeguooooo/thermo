// QA-only code injected before the production entry point in an isolated remote build.
@MainActor
private struct HistoryAXVisibleProbeRoot: View {
    @State private var mode = 0
    private let small: HistoryModel
    private let large: HistoryModel
    init() {
        func records(_ count: Int) -> [OperationRecord] {
            (0..<count).map { i in
                OperationRecord(id: "owned-ax-\(i)", time: Date().addingTimeInterval(-Double(i) * 60),
                    feature: "fixture", action: "verify", subject: "Owned row \(i + 1)",
                    items: [.init(target: "/owned-ax-fixture/row-\(i + 1)", bytes: 1024, status: "done")])
            }
        }
        let three = records(3), many = records(300)
        small = HistoryModel(reader: { .init(records: three) }, didRestore: { _ in })
        large = HistoryModel(reader: { .init(records: many) }, didRestore: { _ in })
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Baseline") { mode = 0 }
                Button("History 3") { mode = 1 }
                Button("History 300") { mode = 2 }
                Button("Contained 300") { mode = 3 }
                Spacer()
                Button("Quit probe") { NSApplication.shared.terminate(nil) }
            }.padding(12)
            Group {
                switch mode {
                case 1: HistoryPage(model: small, open: { _ in }).id(mode)
                case 2: HistoryPage(model: large, open: { _ in }).id(mode)
                case 3: HistoryPage(model: large, open: { _ in }).id(mode).accessibilityElement(children: .contain)
                default:
                    WindowPage(title: "Owned AX baseline", subtitle: "Visible positive control") {
                        Text("Owned baseline text")
                        Button("Owned baseline button") { }
                    }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }.background(Color(red: 0.06, green: 0.08, blue: 0.16)).preferredColorScheme(.dark)
    }
}

@MainActor
private final class HistoryAXVisibleProbeDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    func applicationDidFinishLaunching(_ notification: Notification) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 880, height: 620),
                         styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        w.title = "Owned History AX Probe"
        w.contentView = NSHostingView(rootView: HistoryAXVisibleProbeRoot())
        w.center(); w.makeKeyAndOrderFront(nil); window = w
        NSApplication.shared.activate(ignoringOtherApps: true)
        Timer.scheduledTimer(withTimeInterval: 180, repeats: false) { _ in
            MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

if Bundle.main.bundleIdentifier == "dev.thermo.history-ax.probe.owned" || CommandLine.arguments.contains("--qa-visible-history-ax") {
    MainActor.assumeIsolated {
        let qaApp = NSApplication.shared
        qaApp.setActivationPolicy(.regular)
        let qaDelegate = HistoryAXVisibleProbeDelegate()
        qaApp.delegate = qaDelegate
        withExtendedLifetime(qaDelegate) { qaApp.run() }
    }
    exit(0)
}
