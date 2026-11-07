import AVKit
import AppKit
import CleanKit
import CloudDriveKit
import MediaToolsKit
import SwiftUI
import ThermoL10n
import UniformTypeIdentifiers
import VideoKit

/// One column with one job: paste a link, see what it holds, watch it download. Accounts and
/// settings are a click away in the toolbar, not part of the flow.
struct YunXDownloadPage: View {
    @ObservedObject var model: YunXDownloadModel
    @ObservedObject var setup: YunXChromeUseSetup = .shared
    @State private var accountsShown = false
    @State private var settingsShown = false

    /// A column narrower than the page reads as one task, and keeps the size column near the name.
    /// It starts where every other page starts, so switching pages does not shift the title.
    static let columnWidth: CGFloat = 760

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.xl) {
                header
                if model.keychainAuthorizationRequired { keychainAuthorization }
                if setup.state == .missing || setup.state == .notConnected { YunXChromeUseCard(setup: setup) }
                pasteField
                messages
                if model.browsing { YunXFileList(model: model) }
                if let video = model.video { YunXVideoList(model: model, video: video) }
                if !model.jobs.isEmpty { YunXJobList(model: model) }
                if !model.browsing, model.video == nil, model.jobs.isEmpty { emptyState }
            }
            .frame(maxWidth: Self.columnWidth, alignment: .leading)
            .frame(maxWidth: Theme.pageWidth, alignment: .leading)
            .padding(.horizontal, Theme.pagePadding).padding(.top, Theme.pageTop).padding(.bottom, Theme.Space.xxl)
            .frame(maxWidth: .infinity)
        }
        // The Theme is drawn for the dark window; a light system must not recolor fields on it.
        .environment(\.colorScheme, .dark)
        .onAppear {
            // Keychain first, in the background; the authorization state follows once it has answered.
            model.reloadAccountsInBackground()
            model.startBackgroundRefresh()
            Task { await setup.refresh() }
        }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { withAnimation(Theme.quick) { model.notice = nil } }
        }
        .onChange(of: model.link) { _ in if model.passcode.isEmpty { model.passcodeAsked = false } }
        .sheet(isPresented: $accountsShown) { YunXAccountsSheet(model: model, setup: setup) }
        .sheet(isPresented: $settingsShown) { YunXSettingsSheet(model: model) }
        .sheet(item: Binding(get: { model.preview }, set: { if $0 == nil { model.closePreview() } })) { preview in
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                HStack {
                    Text(preview.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button(tr("Close")) { model.closePreview() }.buttonStyle(PillButtonStyle())
                }
                VideoPlayer(player: preview.player).onAppear { preview.player.play() }
            }.padding(Theme.Space.m).frame(width: 760, height: 500)
        }
        .sheet(isPresented: Binding(get: { model.savePicker != nil }, set: { if !$0 { model.savePicker = nil } })) {
            YunXSavePickerSheet(model: model)
        }
        .sheet(isPresented: Binding(get: { model.torrentPick != nil }, set: { if !$0 { model.cancelTorrent() } })) {
            YunXTorrentSheet(model: model)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            Text(tr("YunX Download")).font(Theme.pageTitle).foregroundStyle(Theme.textPrimary).accessibilityAddTraits(.isHeader)
            StatusTag(text: tr("Experimental")).help(tr("Experimental · not verified with real accounts"))
            Spacer()
            YunXToolbarButton(symbol: "person.crop.circle", label: tr("Accounts")) { accountsShown = true }
            YunXToolbarButton(symbol: "gearshape", label: tr("Download settings")) { settingsShown = true }
        }
    }

    private var keychainAuthorization: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "lock.shield").foregroundStyle(Theme.textSecondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(tr("Saved logins are locked")).font(Theme.body).foregroundStyle(Theme.textPrimary)
                Text(tr("Allow access to restore your accounts and downloads. Thermo will not ask automatically."))
                    .font(Theme.caption).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if model.authorizingKeychain { ProgressView().controlSize(.small) }
            Button(tr("Allow Keychain access")) { Task { await model.authorizeKeychain() } }
                .buttonStyle(PillButtonStyle(prominent: true))
                .disabled(model.authorizingKeychain)
        }
        .padding(Theme.Space.m)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(Theme.surfaceRaised))
    }

    private var pasteField: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "link").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                TextField(tr("Paste a share, video or magnet link"), text: $model.link)
                    .textFieldStyle(.plain).font(.system(size: 15))
                    .onSubmit { Task { await model.open() } }
                if model.busy { ProgressView().controlSize(.small) }
                Button(tr("Open")) { Task { await model.open() } }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(model.busy || model.link.isEmpty)
            }
            .padding(.leading, 14).padding(.trailing, 8).frame(height: 48)
            .background(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).fill(Theme.surfaceRaised))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).strokeBorder(Theme.border))
            HStack(spacing: Theme.Space.m) {
                if model.passcodeAsked || !model.passcode.isEmpty {
                    TextField(tr("Passcode (if any)"), text: $model.passcode)
                        .textFieldStyle(.plain).font(Theme.body)
                        .onSubmit { Task { await model.open() } }
                        .padding(.horizontal, 10).frame(width: 160, height: 28)
                        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).fill(Theme.surface))
                        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall, style: .continuous).strokeBorder(Theme.hairline))
                }
                Spacer()
                Button(tr("Open .torrent…")) { pickTorrent() }
                    .buttonStyle(.plain).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
            }
        }
    }

    @ViewBuilder private var messages: some View {
        if let error = model.error { NoticeBanner(text: error, dismiss: { model.error = nil }) }
        if let notice = model.notice { NoticeBanner(text: notice, dismiss: { model.notice = nil }).transition(.opacity) }
        if model.importingLogin { NoticeBanner(text: tr("Checking your Chrome login…"), busy: true) }
        if let target = model.chromeWaiting { YunXChromeWaiting(model: model, target: target) }
        if let url = model.pendingP2P {
            prompt(tr("P2P downloads need the Gopeed engine, fetched from its GitHub release."), decline: tr("Cancel"), { model.pendingP2P = nil }) {
                Task { await model.installP2P() }
            }.id(url)
        }
        if model.installingP2P { NoticeBanner(text: tr("Installing the P2P engine…"), busy: true) }
        if model.pendingFfmpeg != nil {
            prompt(tr("Merging video and audio works best with FFmpeg, fetched from martin-riedl.de."), decline: tr("Use built-in"), { model.declineFfmpeg() }) {
                Task { await model.installFfmpeg() }
            }
        }
        if model.installingFfmpeg { NoticeBanner(text: tr("Installing FFmpeg…"), busy: true) }
    }

    private func prompt(_ text: String, decline: String, _ no: @escaping () -> Void, install: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(text).font(Theme.secondary).foregroundStyle(Theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(decline, action: no).buttonStyle(PillButtonStyle()).controlSize(.small)
            Button(tr("Install"), action: install).buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).fill(Theme.surface))
    }

    /// Says what the field takes, then stays out of the way.
    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 0) {
            hint("externaldrive.badge.icloud", tr("Drive shares"), tr("Quark, UC, Xunlei, 115, 123, 139 and more"))
            hint("play.rectangle", tr("Video pages"), tr("Bilibili, Douyin, Xiaohongshu, Kuaishou, Weibo, AcFun, Pixiv"))
            hint("arrow.triangle.branch", tr("Magnets and torrents"), tr("Pick the files you want before it starts"))
        }
        .padding(.top, Theme.Space.s)
    }

    private func hint(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Theme.textTertiary).frame(width: 22).accessibilityHidden(true)
            Text(title).font(Theme.body).foregroundStyle(Theme.textSecondary).frame(width: 110, alignment: .leading)
            Text(detail).font(Theme.secondary).foregroundStyle(Theme.textTertiary).lineLimit(1)
            Spacer(minLength: 0)
        }.frame(height: 34)
    }

    private func pickTorrent() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "torrent") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.openTorrent(url) }
    }
}

struct YunXToolbarButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 14, weight: .medium))
                .foregroundStyle(hover ? Theme.textPrimary : Theme.textSecondary)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hover ? Theme.surfaceRaised : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).onHover { hover = $0 }.help(label).accessibilityLabel(label)
    }
}

/// A small icon that shows on a hovered row.
struct YunXRowIcon: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.textSecondary)
                .frame(width: 24, height: 24).contentShape(Rectangle())
        }.buttonStyle(.plain).help(label).accessibilityLabel(label)
    }
}

struct YunXChromeWaiting: View {
    @ObservedObject var model: YunXDownloadModel
    let target: YunXLoginTarget

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            ProgressView().controlSize(.small)
            Text(tr("Finish signing in to %1$@ in Chrome", target.title)).font(Theme.secondary).foregroundStyle(Theme.textPrimary)
            Spacer()
            Button(tr("Cancel")) { model.cancelChromeLogin() }.buttonStyle(PillButtonStyle()).controlSize(.small)
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radiusSmall + 2, style: .continuous).strokeBorder(Theme.hairline))
    }
}

/// Fixed column widths, shared by the file list and the downloads, so sizes line up down the page.
private enum Columns {
    static let size: CGFloat = 112
    static let trailing: CGFloat = 84
}

struct YunXFileList: View {
    @ObservedObject var model: YunXDownloadModel

    private var pickable: [DriveFile] { model.files }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            breadcrumbs
            InspectorPanel {
                HStack(spacing: Theme.Space.s) {
                    SelectAllButton(available: pickable.count, selected: model.selected.count,
                                    selectAll: { model.selected = Set(pickable.map(\.id)) }, clear: { model.selected = [] })
                    Spacer()
                    if model.canSaveToDrive {
                        Button(tr("Save to drive")) { Task { await model.beginSave() } }
                            .buttonStyle(PillButtonStyle()).controlSize(.small).disabled(model.selected.isEmpty)
                    }
                    Button(tr("Download selected")) { model.downloadSelected() }
                        .buttonStyle(PillButtonStyle(prominent: true)).controlSize(.small).disabled(model.selected.isEmpty)
                }
                .padding(.horizontal, Theme.Space.m).frame(height: 40)
                Rectangle().fill(Theme.hairline).frame(height: 1)
                if model.files.isEmpty {
                    if model.busy { SkeletonBar(height: 10).padding(Theme.Space.l) }
                    else { EmptyState(symbol: "folder", title: tr("This folder is empty.")) }
                }
                ForEach(Array(model.files.enumerated()), id: \.element.id) { index, file in
                    if index > 0 { InspectorDivider(inset: 0) }
                    YunXFileRow(model: model, file: file)
                }
            }
        }
    }

    private var breadcrumbs: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.path.enumerated()), id: \.offset) { index, item in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.textTertiary).accessibilityHidden(true)
                }
                Button(item.name) { Task { await model.goUp(to: index) } }
                    .buttonStyle(.plain).lineLimit(1).truncationMode(.middle)
                    .font(index == model.path.count - 1 ? Theme.rowTitle : Theme.body)
                    .foregroundStyle(index == model.path.count - 1 ? Theme.textPrimary : Theme.textSecondary)
                    .allowsHitTesting(index != model.path.count - 1)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 2)
    }
}

struct YunXFileRow: View {
    @ObservedObject var model: YunXDownloadModel
    let file: DriveFile
    @State private var hover = false

    private var selected: Bool { model.selected.contains(file.id) }

    private func toggle() {
        if selected { model.selected.remove(file.id) } else { model.selected.insert(file.id) }
    }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            SelectToggle(selected: selected, label: file.name, toggle: toggle)
            Image(systemName: file.isDirectory ? "folder.fill" : YunXFileIcon.symbol(file.name)).font(.system(size: 13))
                .foregroundStyle(file.isDirectory ? Theme.accent : Theme.textTertiary).frame(width: 18).accessibilityHidden(true)
            Text(file.name).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(file.isDirectory ? "" : ByteFormat.string(file.size)).font(Theme.figure(.row, weight: .regular)).foregroundStyle(Theme.textSecondary)
                .frame(width: Columns.size, alignment: .trailing)
            HStack(spacing: 0) {
                Spacer(minLength: 0)
                if hover {
                    if model.previewable(file) { YunXRowIcon(symbol: "play", label: tr("Preview")) { Task { await model.preview(file) } } }
                    YunXRowIcon(symbol: "arrow.down.to.line", label: tr("Download")) { model.downloadSelected(only: file) }
                } else if file.isDirectory {
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.textTertiary)
                        .frame(width: 24, height: 24).accessibilityHidden(true)
                }
            }.frame(width: Columns.trailing)
        }
        .padding(.leading, Theme.Space.s).padding(.trailing, Theme.Space.m).frame(height: 36)
        .background(selected ? Theme.accent.opacity(0.13) : hover ? Theme.surface : .clear)
        .contentShape(Rectangle())
        .onTapGesture { if file.isDirectory { Task { await model.enter(file) } } else { toggle() } }
        .onHover { hover = $0 }
    }
}

enum YunXFileIcon {
    static func symbol(_ name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mkv", "mov", "avi", "webm", "flv", "ts", "wmv", "rmvb": return "film"
        case "mp3", "flac", "m4a", "wav", "aac": return "music.note"
        case "jpg", "jpeg", "png", "gif", "webp", "heic": return "photo"
        case "zip", "rar", "7z", "tar", "gz": return "doc.zipper"
        default: return "doc"
        }
    }
}

struct YunXVideoList: View {
    @ObservedObject var model: YunXDownloadModel
    let video: VideoParseResult

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            VStack(alignment: .leading, spacing: 2) {
                Text(video.title.isEmpty ? video.platform.displayName : video.title).font(Theme.heading).foregroundStyle(Theme.textPrimary).lineLimit(2)
                ForEach([video.author, video.notice].filter { !$0.isEmpty }, id: \.self) {
                    Text($0).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                }
            }.padding(.horizontal, 2)
            InspectorPanel {
                if !video.qualities.isEmpty {
                    Picker(tr("Quality"), selection: Binding(get: { video.selectedQn }, set: { qn in Task { await model.selectQuality(qn) } })) {
                        ForEach(video.qualities, id: \.qn) { Text($0.label).tag($0.qn) }
                    }.frame(maxWidth: 240).padding(Theme.Space.s)
                    Rectangle().fill(Theme.hairline).frame(height: 1)
                }
                ForEach(Array(video.medias.enumerated()), id: \.offset) { index, media in
                    if index > 0 { InspectorDivider(inset: Theme.Space.m) }
                    HStack(spacing: Theme.Space.s) {
                        Text(YunXDownloadModel.fileName(media, title: video.title)).font(Theme.body).foregroundStyle(Theme.textPrimary)
                            .lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading)
                        if !media.quality.isEmpty { Text(media.quality).font(Theme.secondary).foregroundStyle(Theme.textSecondary) }
                        if model.previewable(media) { YunXRowIcon(symbol: "play", label: tr("Preview")) { Task { await model.preview(media) } } }
                        YunXRowIcon(symbol: "arrow.down.to.line", label: tr("Download")) { model.download(media) }
                    }.padding(.horizontal, Theme.Space.m).frame(height: 36)
                }
            }
        }
    }
}

struct YunXJobList: View {
    @ObservedObject var model: YunXDownloadModel
    @State private var collapsed: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: tr("Downloads")) {
                Button(model.leftoverBytes > 0 ? tr("Clear finished (frees %1$@)", ByteFormat.string(model.leftoverBytes)) : tr("Clear finished")) { model.clearFinished() }
                    .buttonStyle(.plain).font(Theme.secondary).foregroundStyle(Theme.textSecondary)
                    .disabled(!model.jobs.contains { !$0.state.isActive })
            }
            InspectorPanel {
                let groups = model.jobGroups
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    if index > 0 { InspectorDivider(inset: 0) }
                    if group.isFolder {
                        groupRow(group)
                        if !collapsed.contains(group.id) {
                            ForEach(group.jobs) { job in
                                InspectorDivider(inset: 40)
                                YunXJobRow(model: model, job: job, indent: 22)
                            }
                        }
                    } else if let job = group.jobs.first {
                        YunXJobRow(model: model, job: job, indent: 0)
                    }
                }
            }
        }
    }

    private func groupRow(_ group: YunXJobGroup) -> some View {
        let shut = collapsed.contains(group.id)
        return Button {
            withAnimation(Theme.quick) { if shut { collapsed.remove(group.id) } else { collapsed.insert(group.id) } }
        } label: {
            HStack(spacing: Theme.Space.s) {
                DisclosureChevron(expanded: !shut)
                Image(systemName: "folder.fill").font(.system(size: 13)).foregroundStyle(Theme.accent).accessibilityHidden(true)
                Text(group.title).font(Theme.rowTitle).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(tr("%1$@ files", String(group.jobs.count))).font(Theme.caption).foregroundStyle(Theme.textTertiary)
                Spacer(minLength: Theme.Space.s)
                Text(group.total > 0 ? "\(ByteFormat.string(group.received)) / \(ByteFormat.string(group.total))" : "")
                    .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                    .frame(width: Columns.size + Columns.trailing, alignment: .trailing)
            }
            .padding(.leading, Theme.Space.s).padding(.trailing, Theme.Space.m).frame(height: 36).contentShape(Rectangle())
        }.buttonStyle(.plain).hoverHighlight()
    }
}

struct YunXJobRow: View {
    @ObservedObject var model: YunXDownloadModel
    let job: YunXJob
    let indent: CGFloat
    @State private var hover = false

    private var failure: String? { if case let .failed(message) = job.state { return message } else { return nil } }

    var body: some View {
        HStack(spacing: Theme.Space.s) {
            Image(systemName: YunXFileIcon.symbol(job.name)).font(.system(size: 13)).foregroundStyle(Theme.textTertiary).frame(width: 18).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.name).font(Theme.body).foregroundStyle(Theme.textPrimary).lineLimit(1).truncationMode(.middle)
                if job.state.isActive { progress }
                if let failure {
                    Text(Self.explain(failure, held: job.received)).font(Theme.caption).foregroundStyle(Theme.danger).lineLimit(2).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(sizeText).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.textSecondary)
                .lineLimit(1).frame(width: Columns.size, alignment: .trailing)
            ZStack(alignment: .trailing) {
                Text(statusText).font(Theme.caption.monospacedDigit()).foregroundStyle(statusColor).lineLimit(1).opacity(hover && hasActions ? 0 : 1)
                if hover { HStack(spacing: 0) { actions } }
            }.frame(width: Columns.trailing, height: 24, alignment: .trailing)
        }
        .padding(.leading, Theme.Space.m + indent).padding(.trailing, Theme.Space.m).padding(.vertical, 8)
        .frame(minHeight: 40)
        .background(hover ? Theme.surface : .clear)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
    }

    /// A thin bar, so a long list of downloads stays calm.
    private var progress: some View {
        GeometryReader { box in
            let share = job.total.map { $0 > 0 ? min(1, Double(job.received) / Double($0)) : 0 } ?? 0
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.surfaceRaised)
                Capsule().fill(job.state == .paused ? Theme.textTertiary : Theme.accent).frame(width: share > 0 ? max(3, box.size.width * share) : 0)
            }
        }.frame(height: 3).accessibilityHidden(true)
    }

    private var sizeText: String {
        switch job.state {
        case .finished: return job.total.map(ByteFormat.string) ?? ByteFormat.string(job.received)
        default:
            guard job.received > 0 || job.total != nil else { return "" }
            return ByteFormat.string(job.received) + (job.total.map { " / " + ByteFormat.string($0) } ?? "")
        }
    }

    private var statusText: String {
        switch job.state {
        case .queued: return tr("Queued")
        case .running: return job.speed > 0 ? "\(ByteFormat.string(Int64(job.speed)))/s" : ""
        case .paused: return tr("Paused")
        case .notStarted: return tr("Not started")
        case .finished: return tr("Finished")
        case .failed: return tr("Failed")
        case .cancelled: return tr("Cancelled")
        }
    }

    private var statusColor: Color {
        switch job.state {
        case .failed: return Theme.danger
        case .finished: return Theme.good
        default: return Theme.textSecondary
        }
    }

    private var hasActions: Bool {
        switch job.state {
        case .failed: return true
        case .cancelled: return false
        default: return true
        }
    }

    /// The disk-full error in plain words, with what the unfinished parts still occupy.
    static func explain(_ failure: String, held: Int64) -> String {
        let lower = failure.lowercased()
        guard lower.contains("enough space") || lower.contains("no space left") else { return failure }
        return held > 0 ? tr("The disk is full, so it could not be saved. The downloaded parts still take %1$@; remove them to get the space back.", ByteFormat.string(held))
                        : tr("The disk is full, so it could not be saved.")
    }

    @ViewBuilder private var actions: some View {
        switch job.state {
        case .queued:
            YunXRowIcon(symbol: "xmark", label: tr("Cancel")) { model.cancel(job) }
        case .running:
            if job.canPause { YunXRowIcon(symbol: "pause", label: tr("Pause")) { model.pause(job) } }
            YunXRowIcon(symbol: "xmark", label: tr("Cancel")) { model.cancel(job) }
        case .paused, .notStarted:
            YunXRowIcon(symbol: "play", label: tr("Resume")) { model.resume(job) }
            YunXRowIcon(symbol: "xmark", label: tr("Cancel")) { model.cancel(job) }
        case let .finished(url):
            YunXRowIcon(symbol: "magnifyingglass", label: tr("Show in Finder")) { model.reveal(url) }
        case .failed:
            if job.canRetry { YunXRowIcon(symbol: "arrow.clockwise", label: tr("Retry")) { model.resume(job) } }
            // A failed download keeps its parts on disk; removing the row deletes them.
            YunXRowIcon(symbol: "trash", label: job.received > 0 ? tr("Remove and free %1$@", ByteFormat.string(job.received)) : tr("Remove")) { model.discard(job) }
        case .cancelled: EmptyView()
        }
    }
}

/// Picks the folder in the account that a share is saved into.
struct YunXSavePickerSheet: View {
    @ObservedObject var model: YunXDownloadModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(tr("Save to drive")).font(.headline)
            if let picker = model.savePicker {
                HStack(spacing: 4) {
                    ForEach(Array(picker.trail.enumerated()), id: \.offset) { index, item in
                        if index > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(Theme.textTertiary) }
                        Button(item.name) { Task { await model.pickerUp(to: index) } }.buttonStyle(.link).lineLimit(1)
                    }
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(picker.folders, id: \.id) { folder in
                            Button(folder.name) { Task { await model.pickerEnter(folder) } }.buttonStyle(.link).lineLimit(1)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: 220)
            }
            HStack {
                Spacer()
                Button(tr("Cancel")) { model.savePicker = nil; dismiss() }.buttonStyle(PillButtonStyle())
                Button(tr("Save here")) { Task { await model.confirmSave() } }.buttonStyle(PillButtonStyle(prominent: true))
            }
        }.padding(Theme.Space.l).frame(width: 420)
    }
}

/// Which files of a torrent to fetch.
struct YunXTorrentSheet: View {
    @ObservedObject var model: YunXDownloadModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(model.torrentPick?.name ?? "").font(.headline).lineLimit(2)
            if let pick = model.torrentPick {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(pick.files.enumerated()), id: \.offset) { index, file in
                            Toggle(isOn: Binding(get: { model.torrentPick?.selected.contains(index) == true }, set: { on in
                                if on { model.torrentPick?.selected.insert(index) } else { model.torrentPick?.selected.remove(index) }
                            })) {
                                HStack {
                                    Text(file.displayPath).lineLimit(1)
                                    Spacer()
                                    Text(ByteFormat.string(file.size)).font(.caption).foregroundStyle(Theme.textSecondary)
                                }
                            }.toggleStyle(.checkbox)
                        }
                    }
                }.frame(height: 280)
            }
            HStack {
                Spacer()
                Button(tr("Cancel")) { model.cancelTorrent() }.buttonStyle(PillButtonStyle())
                Button(tr("Download selected")) { model.confirmTorrent() }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(model.torrentPick?.selected.isEmpty != false)
            }
        }.padding(Theme.Space.l).frame(width: 520)
    }
}

/// Asks for the backup password, then the place to save it.
struct YunXBackupSheet: View {
    @ObservedObject var model: YunXDownloadModel
    let mode: YunXAccountsSheet.BackupMode
    @State private var password = ""
    @Environment(\.dismiss) private var dismiss

    private var isExport: Bool { if case .export = mode { return true } else { return false } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            Text(isExport ? tr("Export backup") : tr("Import backup")).font(.headline)
            Text(isExport ? tr("The backup is encrypted with this password of at least 8 characters. It cannot be recovered.") : tr("Leave empty if the backup is not encrypted."))
                .font(.callout).foregroundStyle(Theme.textSecondary)
            SecureField(tr("Password"), text: $password).textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button(tr("Cancel")) { dismiss() }.buttonStyle(PillButtonStyle())
                Button(isExport ? tr("Export…") : tr("Import")) { run() }
                    .buttonStyle(PillButtonStyle(prominent: true)).disabled(isExport && password.utf16.count < 8)
            }
        }.padding(Theme.Space.l).frame(width: 380)
    }

    private func run() {
        let secret = password
        switch mode {
        case .export:
            let panel = NSSavePanel()
            panel.nameFieldStringValue = AuthBackupManager.defaultFileName()
            guard panel.runModal() == .OK, let url = panel.url else { return }
            Task { await model.exportBackup(password: secret, to: url) }
        case let .restore(url):
            Task { await model.importBackup(url, password: secret) }
        }
        dismiss()
    }
}

/// A password or SMS login, for platforms with no web login. Everything else signs in through Chrome.
struct YunXLoginSheet: View {
    @ObservedObject var model: YunXDownloadModel
    let target: YunXLoginTarget
    enum Mode: Hashable { case password, sms }
    @State private var mode: Mode?
    @State private var code = ""
    @State private var challenge: YunXSmsChallenge?
    @State private var account = ""
    @State private var password = ""
    @State private var message: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            Text(tr("Sign in to %1$@", target.title)).font(.headline)
            if modes.count > 1 {
                Picker("", selection: Binding(get: { current }, set: { mode = $0; challenge = nil; message = nil })) {
                    ForEach(modes, id: \.self) { Text(title($0)).tag($0) }
                }.pickerStyle(.segmented).labelsHidden()
            }
            switch current {
            case .password:
                TextField(tr("Account"), text: $account).textFieldStyle(.roundedBorder)
                SecureField(tr("Password"), text: $password).textFieldStyle(.roundedBorder)
            case .sms:
                TextField(tr("Phone number"), text: $account).textFieldStyle(.roundedBorder)
                HStack {
                    TextField(tr("Verification code"), text: $code).textFieldStyle(.roundedBorder)
                    Button(challenge == nil ? tr("Send code") : tr("Send again")) { sendCode() }
                        .buttonStyle(PillButtonStyle()).disabled(saving || account.isEmpty)
                }
            }
            if let message { Text(message).font(.callout).foregroundStyle(.red) }
            HStack {
                Spacer()
                if saving { ProgressView().controlSize(.small) }
                Button(tr("Cancel")) { dismiss() }.buttonStyle(PillButtonStyle())
                Button(tr("Save login")) { save() }.buttonStyle(PillButtonStyle(prominent: true)).disabled(saving || !canSave)
            }
        }
        .padding(Theme.Space.l)
        .frame(width: 380)
    }

    private var modes: [Mode] {
        switch target {
        case .drive(.guangya): return [.password, .sms]
        default: return [.password]
        }
    }

    private var current: Mode { mode ?? modes[0] }

    private func title(_ mode: Mode) -> String {
        switch mode {
        case .password: return tr("Password")
        case .sms: return tr("SMS")
        }
    }

    private func sendCode() {
        guard case let .drive(platform) = target else { return }
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do { challenge = try await model.sendSms(platform, phone: account) } catch { message = error.localizedDescription }
        }
    }

    private var canSave: Bool {
        switch current {
        case .sms: return challenge != nil && !account.isEmpty && !code.isEmpty
        case .password: return !account.isEmpty && !password.isEmpty
        }
    }

    private func save() {
        saving = true
        message = nil
        Task {
            defer { saving = false }
            do {
                if current == .sms, let challenge {
                    try await model.smsLogin(phone: account, code: code.trimmingCharacters(in: .whitespaces), challenge: challenge)
                } else if case let .drive(platform) = target {
                    try await model.formLogin(platform, account: account, password: password)
                }
                dismiss()
            } catch { message = error.localizedDescription }
        }
    }
}

