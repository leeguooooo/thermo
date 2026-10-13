import CleanKit
import SwiftUI
import ThermoL10n

struct NativeTabOrganizerView: View {
    let app: String
    let pages: [TabWorkspace.Page]
    @Binding var working: Bool
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
        TabOrganizer.plan(.init(app: app, generated: Date(), pages: pages), rules: config.rules)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(tr("Automatic Chrome groups"), systemImage: "rectangle.3.group.fill").font(.headline)
                Spacer()
                Button(tr("Grouping rules")) { editingRules = true }
                Button(tr("Preview organization")) { review = plan }.disabled(working || plan.count == 0)
                    .buttonStyle(.borderedProminent)
            }
            Text(tr("Creates native Chrome groups by website or your rules. Existing groups, current, pinned, audible, private and agent tabs are kept. Tabs stay in their own window and account."))
                .font(.caption).foregroundStyle(.secondary)
            if plan.unsupported > 0 {
                Text(tr("%1$@ eligible tabs need chrome-use extension 0.5.48 or newer for native grouping.", String(plan.unsupported)))
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle(tr("Keep organizing new tabs automatically"), isOn: Binding(get: { config.enabled }, set: { enabled in
                var updated = config; updated.enabled = enabled
                do { try TabOrganizer.configure(updated); config = updated }
                catch { self.error = error.localizedDescription }
            })).toggleStyle(.checkbox)
            Text(tr("When enabled, Thermo checks every minute while running. Ordinary website groups need two background tabs; a custom rule can group one. No tabs are closed."))
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.orange) }
            if let notice { Text(notice).font(.caption).foregroundStyle(.green) }
            if let latest = records.first(where: { $0.grouped > 0 }) {
                HStack {
                    Text(tr("Last batch: %1$@ tabs grouped", String(latest.grouped))).font(.caption)
                    Spacer()
                    Button(tr("Undo native grouping")) { undo(latest) }
                        .disabled(working || Set(latest.requests.keys).isSubset(of: latest.undoAttempted))
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
                             confirmTitle: tr("Organize tabs"), confirm: { self.review = nil; organize(review) }, cancel: { self.review = nil })
            }
        }
        .sheet(isPresented: $editingRules) { ruleEditor }
    }
    func load() {
        do { config = try TabOrganizer.configuration(); records = try TabOrganizer.batches().filter { $0.app == app } }
        catch { self.error = error.localizedDescription }
    }
    func organize(_ plan: TabOrganizer.Plan) {
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
    var ruleEditor: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(tr("Grouping rules")).font(.headline)
            Text(tr("A domain also matches its subdomains. The first matching rule wins. Rules are saved locally."))
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField(tr("Domain (github.com)"), text: $domain).textFieldStyle(.roundedBorder)
                TextField(tr("Group name"), text: $name).textFieldStyle(.roundedBorder)
                Picker(tr("Color"), selection: $color) { ForEach(TabOrganizer.colors, id: \.self) { Text(tr($0)).tag($0) } }.frame(width: 120)
                Button(tr("Add rule")) {
                    var updated = config; updated.rules.append(.init(domain: domain, name: name, color: color))
                    do { try TabOrganizer.configure(updated); config = updated; domain = ""; name = "" }
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
                                do { try TabOrganizer.configure(updated); config = updated }
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
