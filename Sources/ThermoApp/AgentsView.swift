import AgentDoctor
import AppKit
import SwiftUI

/// Runs the agent doctor off the main thread. A scan spawns ~1 launchctl per launch agent, so it only runs
/// when the tab is opened (and the last result is stale) or on Rescan — never on the sampling timer.
@MainActor
final class AgentScanner: ObservableObject {
    @Published var report: DoctorReport?
    @Published var scanning = false

    func scan(ifOlderThan age: TimeInterval = 0) {
        if scanning { return }
        if let r = report, Date().timeIntervalSince(r.generated) < age { return }
        scanning = true
        Task.detached(priority: .utility) {
            let r = AgentDoctor.run()
            await MainActor.run {
                self.report = r
                self.scanning = false
            }
        }
    }
}

struct AgentsView: View {
    @ObservedObject var scanner: AgentScanner
    @State private var showNotes = false
    @State private var expanded: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if renderingPreview { list } else { ScrollView { list }.frame(height: 330) }
        }
        .onAppear { scanner.scan(ifOlderThan: 300) }
    }

    var summary: some View {
        HStack(alignment: .firstTextBaseline) {
            if let r = scanner.report {
                VStack(alignment: .leading, spacing: 2) {
                    Text(r.headline).font(.callout.bold()).foregroundStyle(color(for: r))
                    Text("\(r.inventory.hooks) hooks · \(r.inventory.mcpServers) MCP · \(r.inventory.plugins) plugins · \(r.inventory.skills) skills · \(r.sessions) sessions")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Checking AI agents…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if scanner.scanning { ProgressView().controlSize(.small) }
            Button("Rescan") { scanner.scan() }.disabled(scanner.scanning).controlSize(.small)
        }
    }

    var list: some View {
        LazyVStack(alignment: .leading, spacing: 4) {
            if let r = scanner.report {
                let shown = r.findings.enumerated().filter { showNotes || $0.element.severity != .info }
                if shown.isEmpty {
                    Text("Hooks, MCP servers, plugins, skills and launch agents look healthy.")
                        .font(.callout).foregroundStyle(.secondary).padding(.vertical, 8)
                }
                ForEach(Area.allCases, id: \.self) { area in
                    let items = shown.filter { $0.element.area == area }
                    if !items.isEmpty {
                        Text(title(area)).font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 6)
                        ForEach(items, id: \.offset) { i, f in row(i, f) }
                    }
                }
                if r.count(.info) > 0 {
                    Toggle("Show \(r.count(.info)) notes", isOn: $showNotes).toggleStyle(.checkbox).font(.caption).padding(.top, 6)
                }
                processes(r)
            }
        }
    }

    func row(_ i: Int, _ f: Finding) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: icon(f.severity)).foregroundStyle(tint(f.severity)).font(.caption)
                Text(f.subject).font(.callout).lineLimit(1).truncationMode(.middle)
                if f.agent != "system" { Text(f.agent).font(.caption2).foregroundStyle(.tertiary) }
                Spacer()
            }
            Text(f.message).font(.caption).foregroundStyle(.secondary)
                .lineLimit(expanded.contains(i) ? nil : 2).fixedSize(horizontal: false, vertical: true)
            if expanded.contains(i) {
                if let fix = f.fix {
                    HStack(alignment: .top) {
                        Text(fix).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(fix, forType: .string)
                        } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless).help("Copy")
                    }
                }
                if let src = f.source { Text(src).font(.caption2.monospaced()).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if expanded.contains(i) { expanded.remove(i) } else { expanded.insert(i) } }
    }

    @ViewBuilder func processes(_ r: DoctorReport) -> some View {
        if !r.processes.isEmpty {
            Text("Agent processes").font(.caption.bold()).foregroundStyle(.secondary).padding(.top, 8)
            ForEach(r.processes.prefix(6), id: \.name) { g in
                HStack {
                    Text("\(g.count)×").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
                    Text(g.name).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    if g.detached > 0 { Text("\(g.detached) detached").foregroundStyle(.orange) }
                    Text(String(format: "%.0f MB", g.rssMB)).monospacedDigit().frame(width: 64, alignment: .trailing)
                }
                .font(.caption)
            }
        }
    }

    func color(for r: DoctorReport) -> Color {
        r.count(.error) > 0 ? .red : r.count(.warning) > 0 ? .orange : .green
    }

    func icon(_ s: Severity) -> String {
        s == .error ? "xmark.octagon.fill" : s == .warning ? "exclamationmark.triangle.fill" : "info.circle"
    }

    func tint(_ s: Severity) -> Color { s == .error ? .red : s == .warning ? .orange : .secondary }

    func title(_ a: Area) -> String {
        switch a {
        case .hooks: return "Hooks"
        case .mcp: return "MCP servers"
        case .plugins: return "Plugins"
        case .skills: return "Skills"
        case .statusline: return "Status line"
        case .launchd: return "Launch agents"
        case .processes: return "Processes"
        }
    }
}
