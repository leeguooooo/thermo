import CleanKit
import SwiftUI
import ThermoL10n

struct NativeTabOrganizerView: View {
    let app: String
    let pages: [TabWorkspace.Page]
    var nativeGroups: [TabWorkspace.NativeGroup] = []
    @Binding var working: Bool
    var previewOnly = false
    let refresh: () -> Void
    @State private var config = TabOrganizer.Configuration()
    @State private var review: TabOrganizer.Plan?
    @State private var records: [TabOrganizer.Batch] = []
    @State private var error: String?
    @State private var notice: String?
    @State private var editingRules = false
    @State private var domain = ""
    @State private var name = ""
    @State private var color = "blue"
    var plan: TabOrganizer.Plan {
        TabOrganizer.plan(.init(app: app, generated: Date(), pages: pages, nativeGroups: nativeGroups), rules: config.rules, batches: records)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.l) {
            // The one figure of the page: what grouping would do, and the button that previews it.
            HStack(alignment: .center, spacing: Theme.Space.l) {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    HStack(spacing: Theme.Space.xs) {
                        Text(tr("Group tabs where you use them")).font(Theme.label).foregroundStyle(Theme.textTertiary)
                        InfoButton(text: tr("Tabs from the same website become a named, colored group in Chrome's tab bar. Nothing is closed.")
                                   + "\n\n" + tr("Preview first. Existing groups and protected tabs stay as they are."))
                    }
                    Text(tr("%1$@ tabs → %2$@ Chrome groups", String(plan.count), String(plan.groups.count)))
                        .font(Theme.figure(.metric)).foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    if plan.count == 0 && !working {
                        Text(plan.unsupported > 0 ? tr("Browser grouping support is unavailable. Update the browser extension, then refresh tabs.")
                             : (plan.waitingForJoin ?? 0) > 0 ? tr("%1$@ websites already have a Thermo group. Update chrome-use so new tabs can join those groups instead of starting another.", String(plan.waitingForJoin ?? 0))
                             : tr("No new groups in this scope. A website needs at least two ungrouped background tabs; existing groups are kept."))
                            .font(Theme.caption).foregroundStyle(plan.unsupported > 0 ? Theme.caution : Theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Theme.Space.s)
                Button { review = plan } label: { Label(tr("Review groups"), systemImage: "eye") }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(working || plan.count == 0)
            }
            .padding(Theme.Space.l).glass()
            if !plan.groups.isEmpty {
                SectionHeader(title: tr("What you will see in Chrome"))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: Theme.Space.m, alignment: .top)], alignment: .leading, spacing: Theme.Space.m) {
                    ForEach(plan.groups) { group in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: Theme.Space.s) {
                                Text(group.name).font(Theme.secondary.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                    .padding(.horizontal, Theme.Space.s).padding(.vertical, 2)
                                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(groupColor(group.color).opacity(0.85)))
                                Spacer()
                                Text(group.groupId != nil ? tr("+%1$@ tabs to the existing group", String(group.pages.count)) : tr("%1$@ tabs", String(group.pages.count)))
                                    .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary)
                            }
                            ForEach(Array(group.pages.prefix(3))) { page in
                                Text(page.tab.title.isEmpty ? TabWorkspace.site(page.tab.url) : page.tab.title)
                                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).lineLimit(1)
                            }
                            if group.pages.count > 3 {
                                Text(tr("and %1$@ more", String(group.pages.count - 3))).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                            }
                        }
                        .padding(Theme.Space.m).frame(maxWidth: .infinity, alignment: .topLeading).glass()
                    }
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: Theme.Space.xs) {
                    Image(systemName: "lock.shield").font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                    Text(tr("Protected tabs are kept")).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    InfoButton(text: tr("Current, pinned, audio, private and agent tabs are not grouped or closed, and tabs already in a group (including chrome-use agent groups) are left where they are. New tabs only join groups Thermo made. Tabs stay in their original window and account."))
                    Spacer()
                }
                .padding(.horizontal, Theme.Space.l).padding(.vertical, 10)
                InspectorDivider(inset: 0)
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
                        Text(tr("Last batch: %1$@ tabs grouped", String(latest.grouped))).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
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
