import AgentDoctor
import AppKit
import SwiftUI
import ThermoL10n

@MainActor
final class ClaudeAccountsModel: ObservableObject {
    static let shared = ClaudeAccountsModel()
    @Published private(set) var profiles: [ClaudeProfile] = []
    @Published private(set) var loaded = false
    @Published var notice: String?

    func refresh() {
        Task {
            let list = await Task.detached { ClaudeProfiles().list() }.value
            profiles = list
            loaded = true
        }
    }

    func create(name: String) -> String? {
        do {
            let profile = try ClaudeProfiles().create(name: name)
            open(profile)
            refresh()
            return nil
        } catch ClaudeProfileError.exists {
            return tr("That name is already in use.")
        } catch ClaudeProfileError.invalidName {
            return tr("Use lowercase letters, digits, - and _.")
        } catch {
            return error.localizedDescription
        }
    }

    /// A `.command` file opens in the user's terminal without asking for Automation access.
    func open(_ profile: ClaudeProfile) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("thermo-claude-\(profile.name).command")
        do {
            try Data("#!/bin/zsh -il\nrm -f \"$0\"\n\(profile.launchCommand)\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
            if !NSWorkspace.shared.open(file) { notice = String(format: tr("Couldn’t open Terminal: %@"), profile.name) }
        } catch {
            notice = String(format: tr("Couldn’t open Terminal: %@"), error.localizedDescription)
        }
    }

    func copy(_ profile: ClaudeProfile) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(profile.launchCommand, forType: .string)
    }
}

struct ClaudeAccountsPage: View {
    @ObservedObject var model: ClaudeAccountsModel
    @State private var creating = false

    var body: some View {
        WindowPage(title: tr("Claude accounts"), subtitle: tr("Each account keeps its own sign-in and history. Choose which one a new terminal runs.")) {
            if let notice = model.notice { NoticeBanner(text: notice) { model.notice = nil } }
            if !model.loaded {
                SkeletonList(rows: 2)
            } else {
                VStack(spacing: Theme.Space.s) {
                    ForEach(model.profiles) { profile in
                        ClaudeAccountCard(profile: profile, open: { model.open(profile) }, copy: { model.copy(profile) })
                    }
                    addCard
                }
            }
            Label(tr("Your own accounts only. Thermo never reads sign-in tokens, and changes nothing about your location or device."), systemImage: "lock")
                .font(Theme.caption).foregroundStyle(Theme.textTertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { model.refresh() }
        .sheet(isPresented: $creating) { NewClaudeAccountSheet(model: model, done: { creating = false }) }
    }

    /// Sits where the next account will appear, so the page says how it grows.
    var addCard: some View {
        Button { creating = true } label: {
            HStack(spacing: Theme.Space.m) {
                Image(systemName: "plus").font(.system(size: 13, weight: .medium)).frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(tr("New account")).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary)
                    Text(tr("Add a personal or work account beside this one.")).font(Theme.secondary)
                }
                Spacer()
            }
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: [4, 4])))
            .hoverHighlight(radius: 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ClaudeAccountCard: View {
    let profile: ClaudeProfile
    let open: () -> Void
    let copy: () -> Void

    var signedOut: Bool { profile.signedIn == false }
    var title: String { profile.email ?? (profile.isDefault ? tr("Default") : profile.name) }
    /// Claude names a personal organization after the email, which says nothing twice.
    var organization: String? {
        guard let name = profile.organization, let email = profile.email, !name.contains(email) else { return nil }
        return name
    }
    var detail: String {
        var parts = [profile.isDefault ? tr("Default") : profile.name]
        if let organization { parts.append(organization) }
        if signedOut { parts.append(tr("Not signed in")) }
        else if profile.signedIn == nil { parts.append(tr("Sign-in unknown")) }
        return parts.joined(separator: " · ")
    }
    var dot: Color { profile.liveSessions > 0 ? .green : signedOut ? Theme.caution : Theme.textTertiary }

    var body: some View {
        InspectorPanel {
            HStack(spacing: Theme.Space.m) {
                ZStack(alignment: .bottomTrailing) {
                    Text(String(title.prefix(1)).uppercased())
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .frame(width: 38, height: 38)
                        .background(Circle().fill(Theme.surfaceRaised))
                    Circle().fill(dot).frame(width: 9, height: 9).accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(Theme.secondary).foregroundStyle(Theme.textSecondary).lineLimit(1)
                }
                Spacer(minLength: Theme.Space.m)
                if profile.liveSessions > 0 {
                    Text(String(format: tr("%@ running"), String(profile.liveSessions)))
                        .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textTertiary).fixedSize()
                }
                Button(action: copy) { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.plain).foregroundStyle(Theme.textSecondary)
                    .help(tr("Copy command")).accessibilityLabel(tr("Copy command"))
                Button(signedOut ? tr("Sign in") : tr("Open in Terminal"), action: open)
                    .buttonStyle(PillButtonStyle()).controlSize(.small).fixedSize()
            }
            .padding(.horizontal, Theme.Space.l).padding(.vertical, Theme.Space.m)
        }
    }
}

private struct NewClaudeAccountSheet: View {
    @ObservedObject var model: ClaudeAccountsModel
    let done: () -> Void
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(tr("New account")).font(Theme.rowTitle)
            TextField(tr("Name"), text: $name).textFieldStyle(.roundedBorder).onSubmit(create)
            Text(error ?? tr("Lowercase letters, digits, - and _. Sign in on first start."))
                .font(Theme.secondary).foregroundStyle(error == nil ? Theme.textSecondary : Theme.danger)
            HStack {
                Spacer()
                Button(tr("Cancel"), action: done).keyboardShortcut(.cancelAction)
                Button(tr("Create and open"), action: create).keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(Theme.Space.l).frame(width: 340)
    }

    func create() {
        error = model.create(name: name)
        if error == nil { done() }
    }
}
