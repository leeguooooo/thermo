import CleanKit
import SwiftUI
import ThermoL10n

struct NativeTabOrganizerView: View {
    let app: String
    let pages: [TabWorkspace.Page]
    var nativeGroups: [TabWorkspace.NativeGroup] = []
    var renameProfiles: [String] = []
    @Binding var working: Bool
    var previewOnly = false
    let refresh: () -> Void
    @State private var config = TabOrganizer.Configuration()
    @State private var review: TabOrganizer.Plan?
    @State private var records: [TabOrganizer.Batch] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var editingRules = false
    @State private var confirmingRename = false
    @State private var domain = ""
    @State private var name = ""
    @State private var color = "blue"
    var plan: TabOrganizer.Plan {
        TabOrganizer.plan(.init(app: app, generated: Date(), pages: pages, nativeGroups: nativeGroups), rules: config.rules, batches: records)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // One card: what grouping would do (or how the tabs stand), then the groups themselves.
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: Theme.Space.l) {
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        if plan.count > 0 || working {
                            Text(headline).font(Theme.figure(.metric)).foregroundStyle(Theme.textPrimary)
                                .contentTransition(.numericText())
                        } else if plan.unsupported > 0 {
                            Text(tr("Browser grouping support is unavailable. Update the browser extension, then refresh tabs."))
                                .font(Theme.secondary).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                        } else if (plan.waitingForJoin ?? 0) > 0 {
                            Text(tr("%1$@ websites already have a Thermo group. Update chrome-use so new tabs can join those groups instead of starting another.", String(plan.waitingForJoin ?? 0)))
                                .font(Theme.secondary).foregroundStyle(Theme.caution).fixedSize(horizontal: false, vertical: true)
                        } else {
                            Label(tr("Nothing to group right now"), systemImage: "checkmark.circle")
                                .font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                        }
                        stats
                    }
                    Spacer(minLength: Theme.Space.s)
                    if plan.count > 0 || working {
                        Button { review = plan } label: { Label(tr("Review groups"), systemImage: "eye") }
                            .buttonStyle(PillButtonStyle(prominent: true)).disabled(working || plan.count == 0)
                    }
                }
                .padding(Theme.Space.l)
                let chips = plan.groups.isEmpty ? currentGroups
                    : plan.groups.map { ($0.name, $0.color, $0.pages.count, $0.groupId != nil) }
                if !chips.isEmpty {
                    InspectorDivider(inset: 0)
                    VStack(alignment: .leading, spacing: Theme.Space.s) {
                        Text(plan.groups.isEmpty ? tr("Groups in Chrome now") : tr("What you will see in Chrome"))
                            .font(Theme.label).foregroundStyle(Theme.textTertiary)
                        TabGroupChips(groups: chips, color: groupColor)
                    }
                    .padding(Theme.Space.l)
                }
                if !renames.isEmpty {
                    InspectorDivider(inset: 0)
                    HStack(spacing: Theme.Space.m) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(tr("%1$@ groups can use the site's name", String(renames.count))).font(Theme.secondary).foregroundStyle(Theme.textPrimary)
                            Text(renames.map { $0.from + " → " + $0.to }.joined(separator: "  ·  "))
                                .font(Theme.caption).foregroundStyle(Theme.textTertiary).lineLimit(2)
                        }
                        Spacer(minLength: Theme.Space.s)
                        Button(tr("Rename")) { confirmingRename = true }
                            .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small).disabled(working || previewOnly)
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
                } else if renameProfiles.isEmpty, currentGroups.contains(where: { $0.name.contains(".") && !$0.name.contains(" ") }) {
                    InspectorDivider(inset: 0)
                    Label(tr("Update chrome-use to rename groups Thermo made with a bare web address."), systemImage: "info.circle")
                        .font(Theme.caption).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
                }
            }
            .glass()
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.s) {
                    Toggle(tr("Automatically group new tabs"), isOn: Binding(get: { config.enabled }, set: { enabled in
                        guard !previewOnly else { return }
                        var updated = config; updated.enabled = enabled
                        do { try TabOrganizer.configure(updated); config = updated }
                        catch { self.error = error.localizedDescription }
                    })).toggleStyle(.switch).controlSize(.small).font(Theme.secondary).foregroundStyle(Theme.textPrimary)
                        .disabled(previewOnly || working)
                    InfoButton(text: tr("Runs once a minute while Thermo is open. It only groups eligible tabs and never closes them."))
                    Spacer()
                    Button(tr("Edit website rules")) { editingRules = true }.buttonStyle(PillButtonStyle()).controlSize(.small)
                        .help(tr("Want your own group names? Add a website rule."))
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, 10)
                if let latest = records.first(where: { $0.grouped > 0 }) {
                    InspectorDivider(inset: 0)
                    HStack {
                        Text(trCount(latest.grouped, "Last batch: %1$@ tab grouped", "Last batch: %1$@ tabs grouped")).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                        Spacer()
                        Button(tr("Undo the last grouping")) { undo(latest) }.buttonStyle(PillButtonStyle()).controlSize(.small)
                            .disabled(working || previewOnly || Set(latest.requests.keys).isSubset(of: latest.undoAttempted))
                    }
                    .padding(.horizontal, Theme.Space.l).padding(.vertical, 10)
                }
            }
            .glass()
            if let error { NoticeBanner(text: error) }
            if let notice { NoticeBanner(text: notice, dismiss: { self.notice = nil }) }
        }
        .onAppear { load() }
        .sheet(isPresented: Binding(get: { review != nil }, set: { if !$0 { review = nil } })) {
            if let review {
                ConfirmSheet(title: tr("Organize %1$@ tabs into %2$@ Chrome groups?", String(review.count), String(review.groups.count)),
                             summary: tr("This changes Chrome's native tab groups. The current page stays active and existing groups are preserved."),
                             destructive: false, heading: tr("Planned groups"),
                             lines: review.groups.map { $0.name + " (" + String($0.pages.count) + ")\n" + $0.pages.map { $0.tab.title }.joined(separator: "\n") },
                             footnote: tr("Each page is rechecked before grouping. Changed or protected pages are skipped. You can undo this batch afterwards."),
                             confirmTitle: tr("Create Chrome groups"), confirm: { self.review = nil; organize(review) }, cancel: { self.review = nil })
            }
        }
        .sheet(isPresented: $editingRules) { ruleEditor }
        .sheet(isPresented: $confirmingRename) {
            ConfirmSheet(title: tr("Rename %1$@ Chrome groups?", String(renames.count)),
                         summary: tr("Only groups Thermo made are renamed, and only if their name has not changed since this check. Tabs are not moved."),
                         destructive: false, heading: tr("Rename"), lines: renames.map { $0.from + " → " + $0.to },
                         footnote: tr("Want your own group names? Add a website rule."),
                         confirmTitle: tr("Rename"), confirm: { confirmingRename = false; rename(renames) }, cancel: { confirmingRename = false })
        }
    }
    /// New groups and joins counted apart: two tabs joining two existing groups is not "2 new groups".
    var headline: String {
        let joining = plan.groups.filter { $0.groupId != nil }.count, new = plan.groups.count - joining
        if joining == 0 { return tr("%1$@ tabs → %2$@ Chrome groups", String(plan.count), String(new)) }
        if new == 0 { return tr("%1$@ tabs → join %2$@ existing groups", String(plan.count), String(joining)) }
        return tr("%1$@ tabs → %2$@ new groups, %3$@ joined", String(plan.count), String(new), String(joining))
    }
    /// The groups Chrome shows for the tabs in scope, largest first.
    var currentGroups: [(name: String, color: String, count: Int, joining: Bool)] {
        let counts = Dictionary(grouping: pages.filter { $0.nativeGroupID != nil && $0.nativeGroupID != -1 }, by: { $0.nativeGroupID! })
        return nativeGroups.compactMap { g in
            counts[g.id].map { (g.title.isEmpty ? tr("Untitled group") : g.title, g.color ?? "grey", $0.count, false) }
        }.sorted { $0.count == $1.count ? $0.name < $1.name : $0.count > $1.count }
    }
    /// How the tabs in scope stand: grouped, the only tab of their site, or kept as they are.
    var stats: some View {
        let grouped = pages.filter { $0.nativeGroupID != nil && $0.nativeGroupID != -1 }.count
        let kept = pages.filter { ($0.nativeGroupID ?? -1) == -1 && !$0.canArchive }.count
        let single = max(0, pages.count - grouped - kept - plan.count)
        return HStack(spacing: Theme.Space.l) {
            stat(grouped, tr("in groups"))
            stat(single, tr("alone on their site"))
            HStack(spacing: 4) {
                stat(kept, tr("kept as they are"))
                InfoButton(text: tr("Current, pinned, audio, private and agent tabs are not grouped or closed, and tabs already in a group (including chrome-use agent groups) are left where they are. New tabs only join groups Thermo made. Tabs stay in their original window and account."))
            }
        }
    }
    func stat(_ n: Int, _ label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(n)).font(Theme.secondary.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.textPrimary)
            Text(label).font(Theme.caption).foregroundStyle(Theme.textTertiary)
        }
    }
    func load() {
        if previewOnly { return }
        do { config = try TabOrganizer.configuration(); records = try TabOrganizer.batches().filter { $0.app == app } }
        catch { self.error = error.localizedDescription }
    }
    func organize(_ plan: TabOrganizer.Plan) {
        guard !previewOnly else { return }
        working = true; error = nil
        Task {
            do {
                let batch = try await Task.detached { try await TabOrganizer.organize(plan) }.value
                notice = tr("Verified %1$@ native group assignments.", String(batch.grouped))
                if !batch.errors.isEmpty { error = batch.errors.values.joined(separator: "\n") }
            } catch { self.error = error.localizedDescription }
            working = false; load(); refresh()
        }
    }
    /// Thermo's own groups still titled with a bare host (or another language's name).
    var renames: [TabOrganizer.Rename] {
        var inventory = TabWorkspace.Inventory(app: app, generated: Date(), pages: pages, nativeGroups: nativeGroups)
        inventory.renameProfiles = renameProfiles
        return TabOrganizer.renames(inventory, batches: records)
    }
    func rename(_ list: [TabOrganizer.Rename]) {
        guard !previewOnly, !list.isEmpty else { return }
        working = true; error = nil
        Task {
            do {
                let count = try await Task.detached { try await TabOrganizer.rename(list, app: app) }.value
                notice = tr("Renamed %1$@ groups.", String(count))
            } catch { self.error = error.localizedDescription }
            working = false; load(); refresh()
        }
    }
    func undo(_ batch: TabOrganizer.Batch) {
        guard !previewOnly else { return }
        working = true; error = nil
        Task {
            do {
                let value = try await Task.detached { try await TabOrganizer.undo(batch.id) }.value
                notice = tr("Verified %1$@ tabs returned to their previous positions.", String(value.restored))
                if !value.errors.isEmpty { error = value.errors.values.joined(separator: "\n") }
            } catch { self.error = error.localizedDescription }
            working = false; load(); refresh()
        }
    }
    func groupColor(_ name: String) -> Color {
        switch name {
        case "red": return .red; case "green": return .green; case "orange": return .orange
        case "purple": return .purple; case "cyan": return .cyan; case "yellow": return .yellow
        case "pink": return .pink; case "grey": return .gray; default: return .blue
        }
    }
    var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Choose names for your website groups")).font(.headline)
            Text(tr("A domain also matches its subdomains. The first matching rule wins. Rules are saved locally."))
                .font(.caption).foregroundStyle(.secondary)
            Text(tr("Example: github.com → Work. Subdomains are included; the first matching rule wins."))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                TextField(tr("Domain (github.com)"), text: $domain).textFieldStyle(.roundedBorder)
                TextField(tr("Group name"), text: $name).textFieldStyle(.roundedBorder)
                Picker(tr("Color"), selection: $color) { ForEach(TabOrganizer.colors, id: \.self) { Text(tr($0)).tag($0) } }.frame(width: 120)
                Button(tr("Add rule")) {
                    var updated = config; updated.rules.append(.init(domain: domain, name: name, color: color))
                    do { if !previewOnly { try TabOrganizer.configure(updated) }; config = updated; domain = ""; name = "" }
                    catch { self.error = error.localizedDescription }
                }.disabled(domain.isEmpty || name.isEmpty)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(config.rules) { rule in
                        HStack {
                            Text(rule.domain + " → " + rule.name)
                            Spacer()
                            Button(tr("Remove rule")) {
                                var updated = config; updated.rules.removeAll { $0.id == rule.id }
                                do { if !previewOnly { try TabOrganizer.configure(updated) }; config = updated }
                                catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
            }.frame(minHeight: 100)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            HStack { Spacer(); Button(tr("Done")) { editingRules = false } }
        }.padding(22).frame(width: 680)
    }
}

/// Chrome-style group labels with their tab counts, wrapping to the width like the tab bar.
struct TabGroupChips: View {
    let groups: [(name: String, color: String, count: Int, joining: Bool)]
    let color: (String) -> Color
    var body: some View {
        ChipFlow(spacing: Theme.Space.s) {
            ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                HStack(spacing: 6) {
                    Text(g.name).font(Theme.secondary.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                        .padding(.horizontal, Theme.Space.s).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color(g.color).opacity(0.85)))
                    Text(g.joining ? tr("+%1$@ to this group", String(g.count)) : String(g.count))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                }
                .help(g.joining ? tr("+%1$@ to this group", String(g.count)) : tr("%1$@ tabs", String(g.count)))
            }
        }
    }
}

/// Lays children left to right and wraps to the next line when the width runs out.
struct ChipFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width { x = 0; y += line + spacing; line = 0 }
            x += size.width + spacing; line = max(line, size.height); widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, width), height: y + line)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
        for v in subviews {
            let size = v.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += line + spacing; line = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; line = max(line, size.height)
        }
    }
}
