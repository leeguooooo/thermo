import AppKit
import CloudDriveKit
import DownloadKit
import Foundation
import MediaToolsKit
import ThermoL10n
import VideoKit

/// What a pasted line is. P2P first: a magnet can carry tracker URLs that look like anything.
enum YunXLink: Equatable {
    case p2p(String)
    case share(ParsedShareLink)
    case video(DetectedVideoLink)

    static func classify(_ text: String) -> YunXLink? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if P2PLink.matches(trimmed) { return .p2p(trimmed) }
        if let share = ShareLinkRouter.parse(trimmed) { return .share(share) }
        if let video = VideoLinkParser.parse(trimmed) { return .video(video) }
        return nil
    }
}

/// How one platform signs in, following YunX's login screens.
enum YunXLoginMethod: Equatable {
    case cookie(url: String, domains: [String], required: [String], anyOf: [String])
    case xunleiWeb
    case form

    static func of(_ platform: DrivePlatform) -> YunXLoginMethod {
        switch platform {
        case .quark: return .cookie(url: QuarkConstants.loginURL, domains: [".quark.cn"], required: ["__pus", "__puus"], anyOf: [])
        case .uc: return .cookie(url: UCConstants.loginURL, domains: [".uc.cn"], required: ["__pus", "__puus"], anyOf: [])
        case .c139:
            return .cookie(url: C139Constants.loginURL, domains: ["mail.10086.cn", "yun.139.com", ".10086.cn"],
                           required: ["Os_SSo_Sid", "RMKEY"], anyOf: ["authorization"])
        case .pan115: return .cookie(url: Pan115Constants.webLoginURL, domains: ["115.com"], required: ["UID", "SEID"], anyOf: [])
        case .xunlei: return .xunleiWeb
        case .pan123, .guangya, .ilanzou, .lanzou: return .form
        }
    }

    static func of(_ platform: VideoPlatform) -> YunXLoginMethod {
        let required: [String]
        switch platform {
        case .bilibili: required = ["SESSDATA"]
        case .xhs: required = ["web_session"]
        case .pixiv: required = ["PHPSESSID"]
        default: required = []
        }
        return .cookie(url: platform.loginUrl, domains: [platform.cookieDomain], required: required, anyOf: [])
    }

    /// The Cookie header once the jar shows a login, else nil. Same test as YunX's `collectCookies`.
    static func detect(_ cookies: [(domain: String, name: String, value: String)], domains: [String], required: [String], anyOf: [String]) -> String? {
        let matching = cookies.filter { cookie in domains.contains { cookie.domain.contains($0) } }
        let names = Set(matching.map(\.name))
        if matching.isEmpty { return nil }
        guard required.allSatisfy(names.contains) || anyOf.contains(where: names.contains) else { return nil }
        return matching.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }
}

/// Reads pan.xunlei.com's session the way YunX's `READ_SCRIPT` does.
enum YunXXunleiWeb {
    static let loginURL = "https://pan.xunlei.com/"
    static let readScript = """
    (function(){try{
      var prefix='credentials_Xqp0kJBXWhwaTpB6';
      var sub=localStorage.getItem('current_sub');
      var raw=sub?localStorage.getItem(prefix+'@'+sub):localStorage.getItem(prefix);
      if(!raw)return '';
      var data=JSON.parse(raw);
      if(!data||typeof data!=='object'||Array.isArray(data))return '';
      if(sub&&data.sub&&String(data.sub)!==sub)return '';
      try{
        var c=JSON.parse(localStorage.getItem('captcha_Xqp0kJBXWhwaTpB6')||'{}');
        if(c&&c.token&&Date.parse(c.expires_at)>Date.now())data.captcha_token=c.token;
      }catch(e){}
      try{
        var all=document.cookie.split(';');
        for(var i=0;i<all.length;i++){
          var s=all[i].trim();
          if(s.indexOf('deviceid=')!==0)continue;
          var d=decodeURIComponent(s.slice(9));
          data.device_id=(d.indexOf('.')>-1&&d.length>32)?d.split('.')[1].slice(0,32):d;
          break;
        }
      }catch(e){}
      return encodeURIComponent(JSON.stringify(data));
    }catch(e){return ''}})()
    """
}

/// Who a login sheet is for.
enum YunXLoginTarget: Identifiable, Equatable {
    case drive(DrivePlatform)
    case video(VideoPlatform)

    var id: String { platform }
    var platform: String {
        switch self {
        case let .drive(p): return p.rawValue
        case let .video(p): return YunXAccount.videoPrefix + p.rawValue
        }
    }
    var title: String {
        switch self {
        case let .drive(p): return YunXNames.drive(p)
        case let .video(p): return p.displayName
        }
    }
    var method: YunXLoginMethod {
        switch self {
        case let .drive(p): return .of(p)
        case let .video(p): return .of(p)
        }
    }
}

enum YunXNames {
    static func drive(_ platform: DrivePlatform) -> String {
        switch platform {
        case .quark: return tr("Quark Drive")
        case .uc: return tr("UC Drive")
        case .xunlei: return tr("Xunlei Drive")
        case .c139: return tr("139 Drive")
        case .pan123: return tr("123 Drive")
        case .pan115: return tr("115 Drive")
        case .guangya: return tr("GuangYa Drive")
        case .ilanzou: return tr("iLanzou")
        case .lanzou: return tr("Lanzou")
        }
    }
}

struct YunXJob: Identifiable, Equatable {
    enum State: Equatable {
        case running, paused, finished(URL), failed(String), cancelled
        var isActive: Bool { self == .running || self == .paused }
    }
    let id: UUID
    var name: String
    var received: Int64 = 0
    var total: Int64?
    var speed: Double = 0
    var state: State = .running
    var canPause = false
}

/// Directories resolved as temporary transfers, emptied when the download ends.
private final class YunXCleanups: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ id: String?) {
        guard let id else { return }
        lock.lock(); ids.append(id); lock.unlock()
    }
    func take() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let all = ids; ids = []
        return all
    }
}

/// The 云析下载 page. Links, cookies and tokens stay in memory or the Keychain; only DownloadKit's
/// own redacted state reaches the disk.
@MainActor
final class YunXDownloadModel: ObservableObject {
    enum Source {
        case share(any CloudDriveProvider, ShareSession, DriveCredential?)
        case drive(any CloudDriveProvider, DriveCredential)
    }

    static let shared = YunXDownloadModel()

    @Published var link = ""
    @Published var passcode = ""
    @Published private(set) var busy = false
    @Published var error: String?
    @Published private(set) var files: [DriveFile] = []
    @Published private(set) var path: [(id: String, name: String)] = []
    @Published private(set) var browsing = false
    @Published var selected: Set<String> = []
    @Published private(set) var video: VideoParseResult?
    @Published private(set) var jobs: [YunXJob] = []
    @Published private(set) var accounts: [YunXAccount] = []
    @Published var login: YunXLoginTarget?
    @Published var pendingP2P: String?
    @Published private(set) var installingP2P = false

    let vault: YunXVault
    private lazy var drives: CloudDriveRegistry = {
        let vault = self.vault
        return CloudDriveRegistry(credentialUpdated: { updated, previous in try? vault.rotate(previous: previous, updated: updated) })
    }()
    private lazy var parsers = VideoParsers()
    private var source: Source?
    private var videoLink: DetectedVideoLink?
    private var tasks: [UUID: DownloadTask] = [:]
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var engine: DownloadEngine?
    private var gopeed: GopeedEngine?

    init(vault: YunXVault = YunXVault()) { self.vault = vault }

    func provider(_ platform: DrivePlatform) -> (any CloudDriveProvider)? { drives.provider(platform) }

    // MARK: Accounts

    func reloadAccounts() {
        do { accounts = try vault.accounts() } catch { self.error = error.localizedDescription }
    }

    func accounts(for platform: String) -> [YunXAccount] { accounts.filter { $0.platform == platform } }

    func remove(_ account: YunXAccount) { edit { try vault.remove(id: account.id) } }
    func makePrimary(_ account: YunXAccount) { edit { try vault.setPrimary(id: account.id) } }

    private func edit(_ change: () throws -> Void) {
        do { try change() } catch { self.error = error.localizedDescription }
        reloadAccounts()
    }

    /// Validates a captured or pasted secret, then stores it. Throws what the sheet should show.
    func saveLogin(_ target: YunXLoginTarget, secret: String, extra: [String: String] = [:]) async throws {
        switch target {
        case let .drive(platform):
            guard let provider = provider(platform) else { throw DriveError.providerUnavailable(platform) }
            var value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if platform == .pan115 { value = Pan115Constants.filterLoginCookies(value) }
            if platform == .xunlei, value.contains("{"), let parsed = XunleiCredential.parseWebLogin(value) { value = parsed.driveCredential.value }
            let credential = DriveCredential(value)
            guard provider.isWellFormed(credential: credential) else { throw YunXLoginError.rejected }
            var nickname = ""
            switch await provider.accountState(credential: credential) {
            case .signedOut: throw YunXLoginError.rejected
            case .unverified: break
            case let .signedIn(name): nickname = name
            }
            var fields = YunXCredentialCodec.fields(platform, credential: credential, base: extra)
            fields["nickname"] = nickname
            try vault.add(platform: platform.rawValue, fields: fields, key: YunXBackupStore.key(platform.rawValue))
        case let .video(platform):
            guard let parser = parsers.of(platform) else { throw YunXLoginError.rejected }
            let cookie = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let nickname = try await parser.validateCookie(cookie) else { throw YunXLoginError.rejected }
            try vault.add(platform: target.platform, fields: ["cookie": cookie, "nickname": nickname, "remark": ""], key: "cookie")
        }
        reloadAccounts()
    }

    /// Password logins. The password is sent once and never stored.
    func formLogin(_ platform: DrivePlatform, account: String, password: String) async throws {
        let secret: String
        switch platform {
        case .pan123:
            switch await Pan123API().passwordLogin(account: account, password: password) {
            case let .success(credential): secret = credential.value
            case let .failure(message): throw DriveError.api(message: message)
            }
        case .guangya: secret = try await GuangYaProvider().login(account: account, password: password).value
        case .ilanzou: secret = try await ILanzouAPI().signIn(loginName: account, loginPwd: password).credential.value
        case .lanzou: secret = try await LanzouAPI().login(account: account, password: password)
        default: throw YunXLoginError.rejected
        }
        try await saveLogin(.drive(platform), secret: secret, extra: ["account": account])
    }

    private func credential(_ platform: DrivePlatform, provider: any CloudDriveProvider) async -> DriveCredential? {
        guard let account = try? vault.active(platform.rawValue) else { return nil }
        let current = YunXCredentialCodec.credential(platform, fields: account.fields)
        guard let interval = provider.credentialRefreshInterval,
              Date().timeIntervalSince1970 * 1000 - Double(account.updatedAt) > interval * 1000,
              let fresh = await provider.refreshCredential(current) else { return current }
        try? vault.rotate(previous: current, updated: fresh)
        return fresh
    }

    // MARK: Backup

    func exportBackup(password: String, to url: URL) async {
        do {
            let content = try await AuthBackupManager(store: YunXBackupStore(vault: vault)).export(password: password)
            try AuthBackupManager.save(content, to: url)
        } catch { self.error = error.localizedDescription }
    }

    func importBackup(_ url: URL, password: String) async {
        do {
            let content = try String(contentsOf: url, encoding: .utf8)
            _ = try await AuthBackupManager(store: YunXBackupStore(vault: vault)).import(content, password: password.isEmpty ? nil : password)
        } catch { self.error = error.localizedDescription }
        reloadAccounts()
    }

    // MARK: Opening links

    private func clearResults() {
        source = nil; files = []; path = []; browsing = false; selected = []; video = nil; videoLink = nil; error = nil
    }

    private func working(_ body: () async throws -> Void) async {
        busy = true
        defer { busy = false }
        do { try await body() } catch is CancellationError {} catch let failure as VideoParseException {
            error = failure.userMessage
        } catch { self.error = error.localizedDescription }
    }

    func open() async {
        clearResults()
        guard let kind = YunXLink.classify(link) else { error = tr("That link is not recognised."); return }
        await working {
            switch kind {
            case let .p2p(url): await addP2P(url)
            case let .share(parsed): try await openShare(parsed)
            case let .video(detected): try await openVideo(detected, qn: nil)
            }
        }
    }

    private func openShare(_ parsed: ParsedShareLink) async throws {
        let (link, provider) = try drives.router.route(self.link)
        let credential = await credential(parsed.platform, provider: provider)
        if credential == nil, !provider.capabilities.contains(.guestShareAccess) { throw DriveError.loginRequired }
        let code = passcode.trimmingCharacters(in: .whitespaces)
        let session = try await provider.openShare(link, passcode: code.isEmpty ? link.passcode : code, credential: credential)
        source = .share(provider, session, credential)
        path = [("", session.title.isEmpty ? YunXNames.drive(parsed.platform) : session.title)]
        browsing = true
        try await list(nil)
    }

    func browseDrive(_ platform: DrivePlatform) async {
        clearResults()
        await working {
            guard let provider = provider(platform) else { throw DriveError.providerUnavailable(platform) }
            guard let credential = await credential(platform, provider: provider) else { throw DriveError.loginRequired }
            source = .drive(provider, credential)
            path = [("", YunXNames.drive(platform))]
            browsing = true
            try await list(nil)
        }
    }

    private func list(_ directory: String?) async throws {
        switch source {
        case let .share(provider, session, credential)?:
            files = try await provider.listShareFiles(session: session, directoryId: directory, credential: credential)
        case let .drive(provider, credential)?:
            files = try await provider.listFiles(directoryId: directory, credential: credential)
        case nil: files = []
        }
        selected = []
    }

    func enter(_ folder: DriveFile) async {
        await working {
            try await list(folder.id)
            path.append((folder.id, folder.name))
        }
    }

    func goUp(to index: Int) async {
        await working {
            try await list(index == 0 ? nil : path[index].id)
            path = Array(path.prefix(index + 1))
        }
    }

    private func openVideo(_ detected: DetectedVideoLink, qn: Int?) async throws {
        guard let parser = parsers.of(detected.platform) else { throw VideoParseException(.unsupported, "") }
        let cookie = (try? vault.active(YunXAccount.videoPrefix + detected.platform.rawValue))?.fields["cookie"] ?? ""
        if let qn, let selectable = parser as? any QualitySelectableParser {
            video = try await selectable.parseWithQuality(detected, cookie: cookie, qn: qn)
        } else {
            video = try await parser.parse(detected, cookie: cookie)
        }
        videoLink = detected
    }

    func selectQuality(_ qn: Int) async {
        guard let videoLink else { return }
        await working { try await openVideo(videoLink, qn: qn) }
    }

    // MARK: Downloads

    private func saveDirectory() -> URL { DownloadSaver.resolveSaveDirectory(custom: nil) }

    private func downloadEngine() throws -> DownloadEngine {
        if let engine { return engine }
        let made = try DownloadEngine()
        engine = made
        return made
    }

    private func update(_ id: UUID, _ change: (inout YunXJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    private func launch(name: String, body: @escaping @MainActor (UUID) async throws -> URL) {
        let id = UUID()
        jobs.insert(YunXJob(id: id, name: name), at: 0)
        runners[id] = Task { [weak self] in
            do {
                let url = try await body(id)
                self?.update(id) { $0.state = .finished(url) }
            } catch is CancellationError {
                self?.update(id) { $0.state = .cancelled }
            } catch DownloadError.cancelled {
                self?.update(id) { $0.state = .cancelled }
            } catch {
                self?.update(id) { $0.state = .failed(error.localizedDescription) }
            }
            self?.tasks[id] = nil
            self?.runners[id] = nil
        }
    }

    /// Runs one transfer under a job and returns where it landed.
    private func fetch(_ id: UUID, url: URL, headers: [String: String], to destination: URL, refresh: LinkRefresher? = nil) async throws -> URL {
        let task = try downloadEngine().makeTask(DownloadRequest(url: url, destination: destination, headers: headers, refreshLink: refresh))
        tasks[id] = task
        update(id) { $0.canPause = true }
        let watcher = Task { [weak self] in
            for await progress in task.progress {
                self?.update(id) { job in
                    job.received = progress.receivedBytes
                    job.total = progress.totalBytes
                    job.speed = progress.bytesPerSecond
                    job.state = progress.phase == .paused ? .paused : .running
                }
            }
        }
        defer { watcher.cancel() }
        await task.start()
        return try await withTaskCancellationHandler {
            try await task.result()
        } onCancel: {
            Task { await task.cancel() }
        }
    }

    private func fetchHLS(_ id: UUID, url: String, headers: [String: String], to destination: URL) async throws -> URL {
        let box = YunXCounter()
        try await HlsDownloader().download(url: url, headers: headers, destination: destination) { [weak self] bytes in
            let total = box.add(bytes)
            await self?.update(id) { $0.received = total }
        }
        return destination
    }

    /// Downloads the ticked files, or just `only`.
    func downloadSelected(only: DriveFile? = nil) {
        guard let source else { return }
        let picked = only.map { [$0] } ?? files.filter { selected.contains($0.id) && !$0.isDirectory }
        selected = []
        for file in picked { download(file, source: source) }
    }

    private func download(_ file: DriveFile, source: Source) {
        let directory = saveDirectory()
        let cleanups = YunXCleanups()
        launch(name: file.name) { [weak self] id in
            guard let self else { throw CancellationError() }
            let resolve: @Sendable () async throws -> ResolvedLink = {
                let link: ResolvedLink
                switch source {
                case let .share(provider, session, credential):
                    link = try await provider.resolveShareFile(session: session, file: file, credential: credential, options: ShareResolveOptions())
                case let .drive(provider, credential):
                    link = try await provider.resolveFile(file, credential: credential)
                }
                cleanups.add(link.cleanupDirectoryId)
                return link
            }
            func finish() async {
                let (provider, credential): ((any CloudDriveProvider), DriveCredential?)
                switch source {
                case let .share(p, _, c): (provider, credential) = (p, c)
                case let .drive(p, c): (provider, credential) = (p, c)
                }
                guard let credential else { return }
                for directory in cleanups.take() { await provider.cleanup(directoryId: directory, credential: credential) }
            }
            do {
                let link = try await resolve()
                let destination = try DownloadSaver.destination(for: DownloadPathPolicy.sanitizeName(link.filename.isEmpty ? file.name : link.filename), in: directory)
                let saved: URL
                if link.isHLS {
                    saved = try await fetchHLS(id, url: link.url.absoluteString, headers: link.headers, to: destination)
                } else {
                    saved = try await fetch(id, url: link.url, headers: link.headers, to: destination) { _ in
                        let fresh = try await resolve()
                        return RefreshedLink(url: fresh.url, headers: fresh.headers)
                    }
                }
                await finish()
                return saved
            } catch {
                await finish()
                throw error
            }
        }
    }

    func download(_ media: VideoMedia) {
        guard let title = video?.title else { return }
        let name = Self.fileName(media, title: title)
        let directory = saveDirectory()
        launch(name: name) { [weak self] id in
            guard let self else { throw CancellationError() }
            let destination = try DownloadSaver.destination(for: name, in: directory)
            if media.isHls { return try await fetchHLS(id, url: media.url, headers: media.headers, to: destination) }
            guard let url = URL(string: media.url) else { throw VideoParseException(.unknown, "") }
            guard !media.audioUrl.isEmpty, let audio = URL(string: media.audioUrl) else {
                return try await fetch(id, url: url, headers: media.headers, to: destination)
            }
            // Separate tracks: fetch both into a private folder, mux, then publish.
            let root = try MediaToolsRoot.applicationSupport()
            let work = try root.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let videoFile = try await fetch(id, url: url, headers: media.headers, to: work.appendingPathComponent("video.m4s"))
            let audioFile = try await fetch(id, url: audio, headers: media.audioHeaders, to: work.appendingPathComponent("audio.m4s"))
            let muxed = work.appendingPathComponent("muxed.mp4")
            guard await MediaMuxer(ffmpeg: FfmpegMuxer(root: root)).mux(video: videoFile, audio: audioFile, out: muxed) else {
                throw YunXLoginError.muxFailed
            }
            return try DownloadSaver.save(muxed, as: name, in: directory)
        }
    }

    nonisolated static func fileName(_ media: VideoMedia, title: String) -> String {
        if !media.fileName.isEmpty { return DownloadPathPolicy.sanitizeName(media.fileName) }
        let ext: String
        switch media.kind {
        case .video: ext = "mp4"
        case .audio: ext = "m4a"
        case .image: ext = "jpg"
        }
        return DownloadPathPolicy.sanitizeName("\(title.isEmpty ? "video" : title).\(ext)")
    }

    func pause(_ job: YunXJob) { Task { await tasks[job.id]?.pause(); update(job.id) { $0.state = .paused } } }
    func resume(_ job: YunXJob) { Task { await tasks[job.id]?.start(); update(job.id) { $0.state = .running } } }
    func cancel(_ job: YunXJob) { runners[job.id]?.cancel() }
    func clearFinished() { jobs.removeAll { !$0.state.isActive } }
    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: P2P through Gopeed

    private func p2pEngine() throws -> GopeedEngine {
        if let gopeed { return gopeed }
        let made = GopeedEngine(root: try MediaToolsRoot.applicationSupport())
        gopeed = made
        return made
    }

    private func addP2P(_ url: String) async {
        do {
            let engine = try p2pEngine()
            guard await engine.isInstalled else { pendingP2P = url; return }
            startP2P(url, engine: engine)
        } catch { self.error = error.localizedDescription }
    }

    /// Fetches the Gopeed kernel, only after the page has asked.
    func installP2P() async {
        guard let url = pendingP2P else { return }
        pendingP2P = nil
        installingP2P = true
        defer { installingP2P = false }
        do {
            let engine = try p2pEngine()
            _ = try await GopeedKernelProvisioner(root: try MediaToolsRoot.applicationSupport()).provision(engine: engine)
            startP2P(url, engine: engine)
        } catch { self.error = error.localizedDescription }
    }

    private func startP2P(_ url: String, engine: GopeedEngine) {
        let directory = saveDirectory()
        let name = P2PLink.displayName(url)
        launch(name: name) { [weak self] id in
            _ = try await engine.start()
            let task = try await engine.createTask(url: url, saveDir: directory.path, fileName: "")
            do {
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let view = try await engine.taskStatus(task)
                    self?.update(id) {
                        $0.received = view.downloaded
                        $0.total = view.total > 0 ? view.total : nil
                        $0.speed = Double(view.speed)
                    }
                    if view.status == GopeedEngine.TaskStatus.done { break }
                    if view.status == GopeedEngine.TaskStatus.error {
                        throw DriveError.api(message: await engine.taskError(task) ?? tr("The download failed."))
                    }
                }
            } catch {
                try? await engine.deleteTask(task)
                if !(await engine.hasActiveTasks()) { await engine.stop() }
                throw error
            }
            if !(await engine.hasActiveTasks()) { await engine.stop() }
            return directory
        }
    }
}

private final class YunXCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var total: Int64 = 0
    func add(_ bytes: Int64) -> Int64 {
        lock.lock(); defer { lock.unlock() }
        total += bytes
        return total
    }
}

enum YunXLoginError: LocalizedError {
    case rejected, muxFailed
    var errorDescription: String? {
        switch self {
        case .rejected: return tr("That login was not accepted. Sign in again.")
        case .muxFailed: return tr("Could not merge the video and audio tracks.")
        }
    }
}
