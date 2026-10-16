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
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 12) {
                Label(tr("Group tabs where you use them"), systemImage: "rectangle.3.group.fill").font(.headline)
                Text(tr("Tabs from the same website become a named, colored group in Chrome's tab bar. Nothing is closed."))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(tr("%1$@ tabs → %2$@ Chrome groups", String(plan.count), String(plan.groups.count)))
                            .font(.system(size: 18, weight: .semibold)).monospacedDigit()
                        Text(tr("Preview first. Existing groups and protected tabs stay as they are."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    Button { review = plan } label: { Label(tr("Review groups"), systemImage: "eye") }
                        .buttonStyle(PillButtonStyle(prominent: true)).disabled(working || plan.count == 0)
                }
                if plan.count == 0 && !working {
                    Text(plan.unsupported > 0 ? tr("Browser grouping support is unavailable. Update the browser extension, then refresh tabs.")
                         : (plan.waitingForJoin ?? 0) > 0 ? tr("%1$@ websites already have a Thermo group. Update chrome-use so new tabs can join those groups instead of starting another.", String(plan.waitingForJoin ?? 0))
                         : tr("No new groups in this scope. A website needs at least two ungrouped background tabs; existing groups are kept."))
                        .font(.caption).foregroundStyle(plan.unsupported > 0 ? Color.orange : .secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            if !plan.groups.isEmpty {
                Text(tr("What you will see in Chrome")).font(.callout.weight(.medium))
                ForEach(plan.groups) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Circle().fill(groupColor(group.color)).frame(width: 10, height: 10)
                            Text(group.name).font(.callout.weight(.semibold)).lineLimit(1)
                            Spacer()
                            Text(group.groupId != nil ? tr("+%1$@ tabs to the existing group", String(group.pages.count)) : tr("%1$@ tabs", String(group.pages.count)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(group.pages.prefix(3))) { page in
                            Text(page.tab.title.isEmpty ? TabWorkspace.site(page.tab.url) : page.tab.title)
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if group.pages.count > 3 { Text(tr("and %1$@ more", String(group.pages.count - 3))).font(.caption2).foregroundStyle(.secondary) }
                    }.padding(12).glass(radius: 10)
                }
            }
            DisclosureGroup(tr("Protected tabs are kept")) {
                Text(tr("Current, pinned, audio, private and agent tabs are not grouped or closed, and tabs already in a group (including chrome-use agent groups) are left where they are. New tabs only join groups Thermo made. Tabs stay in their original window and account."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }.font(.caption)
            DisclosureGroup(tr("Custom rules and automatic grouping")) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(tr("Want your own group names? Add a website rule.")).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button(tr("Edit website rules")) { editingRules = true }
                    }
                    Toggle(tr("Automatically group new tabs"), isOn: Binding(get: { config.enabled }, set: { enabled in
                        guard !previewOnly else { return }
                        var updated = config; updated.enabled = enabled
                        do { try TabOrganizer.configure(updated); config = updated }
                        catch { self.error = error.localizedDescription }
                    })).toggleStyle(.checkbox).disabled(previewOnly || working)
                    Text(tr("Runs once a minute while Thermo is open. It only groups eligible tabs and never closes them."))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }.padding(.top, 8)
            }.font(.caption)
            if let error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            if let notice { Label(notice, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.green) }
            if let latest = records.first(where: { $0.grouped > 0 }) {
                HStack {
                    Text(tr("Last batch: %1$@ tabs grouped", String(latest.grouped))).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button(tr("Undo the last grouping")) { undo(latest) }
                        .disabled(working || previewOnly || Set(latest.requests.keys).isSubset(of: latest.undoAttempted))
                }
            }
        }
        .padding(14).glass(radius: 12)
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
