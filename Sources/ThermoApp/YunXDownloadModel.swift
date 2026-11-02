import AVFoundation
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
      var h=location.hostname;if(h!=='xunlei.com'&&h.slice(-11)!=='.xunlei.com')return '';
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
    /// The page to sign in on in Chrome; nil for a platform that signs in with a form here.
    var chromeURL: String? {
        switch method {
        case let .cookie(url, _, _, _): return url.isEmpty ? nil : url
        case .xunleiWeb: return YunXXunleiWeb.loginURL
        case .form: return nil
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
        case queued, running, paused, finished(URL), failed(String), cancelled
        /// Restored from a run that ended before any transfer began.
        case notStarted
        var isActive: Bool { self == .queued || self == .running || self == .paused || self == .notStarted }
    }
    let id: UUID
    var name: String
    /// `name` with its folders, such as `Folder/Sub/file.mp4`, which groups the list.
    var relativeName = ""
    var saveDirectory = ""
    var savedPath = ""
    /// Counts against the limit on simultaneous HTTP transfers.
    var usesSlot = true
    var received: Int64 = 0
    var total: Int64?
    var speed: Double = 0
    var state: State = .running
    var canPause = false
    /// A saved record exists, so Retry can open the source again.
    var canRetry = false
}

/// A code was sent; holds what the second step needs. Lives only as long as the login sheet.
enum YunXSmsChallenge: Equatable {
    case xunlei(creditKey: String, token: String, device: XunleiDevice)
    case guangya(GuangYaSmsChallenge, GuangYaDevice)
}

struct YunXPreview: Identifiable {
    let id = UUID()
    let title: String
    let player: AVPlayer
}

/// Choosing a folder in the account for "Save to drive".
struct YunXSavePicker: Equatable {
    var items: [DriveFile]
    var trail: [(id: String, name: String)]
    var folders: [DriveFile] = []

    static func == (a: YunXSavePicker, b: YunXSavePicker) -> Bool {
        a.items == b.items && a.folders == b.folders && a.trail.map(\.id) == b.trail.map(\.id)
    }
}

/// Files of one torrent, all ticked until the user says otherwise.
struct YunXTorrentPick: Equatable {
    let url: String
    let name: String
    let files: [GopeedResolvedFile]
    var selected: Set<Int>

    /// Empty means everything to Gopeed.
    var selection: [Int] { selected.count == files.count ? [] : selected.sorted() }
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
    /// The open failed on a share with no code in its link, so the page asks for one.
    @Published var passcodeAsked = false
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
    @Published private(set) var importingLogin = false
    /// Chrome was opened on this platform's login page, and the page is watching for the login.
    @Published private(set) var chromeWaiting: YunXLoginTarget?
    private var chromeWait: Task<Void, Never>?
    var chromePollInterval: Duration = .seconds(3)
    var chromePollTimeout: Duration = .seconds(300)
    @Published var pendingP2P: String?
    @Published private(set) var installingP2P = false
    @Published var notice: String?
    @Published var settings: YunXSettings { didSet { settingsChanged(from: oldValue) } }
    @Published private(set) var preview: YunXPreview?
    @Published var savePicker: YunXSavePicker?
    @Published var torrentPick: YunXTorrentPick?
    @Published var pendingFfmpeg: VideoMedia?
    @Published private(set) var installingFfmpeg = false

    static let maxTransfers = 4
    /// How often accounts are checked; each drive's own interval decides whether one is due.
    static let refreshTick: Duration = .seconds(15 * 60)
    static let refreshRetry: TimeInterval = 3600

    let vault: YunXVault
    private let settingsStore: YunXSettingsStore
    private let jobStore: YunXJobStore
    private let downloadStore: DownloadStore?
    private let toolsRoot: () throws -> MediaToolsRoot
    private let makeEngine: (DownloadConfiguration) throws -> DownloadEngine
    private let xunlei: XunleiAPI
    private let limit: YunXLimitBox
    private let chromeCookies: YunXChromeCookies
    private var drivesOverride: CloudDriveRegistry?
    private lazy var drives: CloudDriveRegistry = {
        if let drivesOverride { return drivesOverride }
        let vault = self.vault
        return CloudDriveRegistry(credentialUpdated: { updated, previous in try? vault.rotate(previous: previous, updated: updated) })
    }()
    private lazy var parsers = VideoParsers()
    private var source: Source?
    private var videoLink: DetectedVideoLink?
    private var shareLink: (link: ParsedShareLink, passcode: String)?
    private var tasks: [UUID: DownloadTask] = [:]
    private var runners: [UUID: Task<Void, Never>] = [:]
    private var engine: DownloadEngine?
    private var gopeed: GopeedEngine?
    private var p2pTasks: [UUID: String] = [:]
    private var refresher: Task<Void, Never>?
    private var retryAfter: [String: Date] = [:]
    private var restored = false
    private var skipFfmpeg = false
    private var previewCleanup: (() async -> Void)?

    init(vault: YunXVault = YunXVault(), settingsStore: YunXSettingsStore = YunXSettingsStore(), jobStore: YunXJobStore = YunXJobStore(),
         drives: CloudDriveRegistry? = nil, downloadStore: DownloadStore? = nil, xunlei: XunleiAPI = XunleiAPI(),
         toolsRoot: @escaping () throws -> MediaToolsRoot = { try MediaToolsRoot.applicationSupport() },
         gopeed: GopeedEngine? = nil, chromeCookies: YunXChromeCookies = .live,
         makeEngine: ((DownloadConfiguration) throws -> DownloadEngine)? = nil) {
        self.vault = vault
        self.settingsStore = settingsStore
        self.jobStore = jobStore
        self.drivesOverride = drives
        self.downloadStore = downloadStore
        self.xunlei = xunlei
        self.toolsRoot = toolsRoot
        self.gopeed = gopeed
        self.chromeCookies = chromeCookies
        self.makeEngine = makeEngine ?? { try DownloadEngine(configuration: $0) }
        let loaded = settingsStore.load()
        settings = loaded
        limit = YunXLimitBox(loaded.speedLimitBytes)
    }

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

    /// The Add button. A platform with a web login signs in only through Chrome: what Chrome already
    /// has is imported, otherwise Chrome opens on the login page and is watched until a login appears.
    /// An account that is already saved also goes to Chrome, or a second one could never be added.
    func addAccount(_ target: YunXLoginTarget) async {
        guard !importingLogin, chromeWaiting == nil else { return }
        guard let url = target.chromeURL else {
            login = target
            return
        }
        let chrome = chromeCookies
        importingLogin = true
        guard await Task.detached(operation: { chrome.available }).value else {
            importingLogin = false
            error = tr("Install chrome-use to sign in.")
            return
        }
        let known = accounts(for: target.platform).count
        if case .cookie = target.method, let secret = await chromeSecret(target, live: false),
           (try? await saveLogin(target, secret: secret, requireVerified: true)) != nil,
           accounts(for: target.platform).count > known {
            importingLogin = false
            notice = tr("Imported from Chrome")
            return
        }
        let opened = await Task.detached { chrome.open(url) }.value
        importingLogin = false
        guard opened else {
            error = tr("Could not open Chrome. Install Google Chrome, then try again.")
            return
        }
        chromeWaiting = target
        let waiter = Task<Void, Never> { [weak self] in await self?.watchChrome(target, known: known) }
        chromeWait = waiter
        await waiter.value
    }

    func cancelChromeLogin() {
        chromeWait?.cancel()
        chromeWait = nil
        chromeWaiting = nil
    }

    private func chromeSecret(_ target: YunXLoginTarget, live: Bool) async -> String? {
        let chrome = chromeCookies
        let method = target.method
        return await Task.detached {
            switch method {
            case let .cookie(_, domains, required, anyOf): return chrome.header(domains: domains, required: required, anyOf: anyOf, live: live)
            case .xunleiWeb: return chrome.xunleiLogin()
            case .form: return nil
            }
        }.value
    }

    /// Only runs while waiting. A login already refused is not re-sent to the drive on every tick,
    /// but is tried again now and then in case the drive was only unreachable.
    private func watchChrome(_ target: YunXLoginTarget, known: Int) async {
        let clock = ContinuousClock()
        let deadline = clock.now + chromePollTimeout
        var refused: String?
        var ticks = 0
        while clock.now < deadline {
            try? await Task.sleep(for: chromePollInterval)
            if Task.isCancelled { return }
            ticks += 1
            guard let secret = await chromeSecret(target, live: true), !Task.isCancelled,
                  secret != refused || ticks % 10 == 0 else { continue }
            if (try? await saveLogin(target, secret: secret, requireVerified: true)) != nil,
               accounts(for: target.platform).count > known {
                chromeWaiting = nil
                chromeWait = nil
                notice = tr("Imported from Chrome")
                return
            }
            refused = secret
        }
        guard !Task.isCancelled else { return }
        chromeWaiting = nil
        chromeWait = nil
        error = tr("No new login appeared in Chrome. Try again.")
    }

    /// Validates a captured secret, then stores it. Throws what the sheet should show.
    /// `requireVerified` refuses a login the provider could not confirm, as when it is unreachable.
    func saveLogin(_ target: YunXLoginTarget, secret: String, extra: [String: String] = [:], requireVerified: Bool = false) async throws {
        switch target {
        case let .drive(platform):
            guard let provider = provider(platform) else { throw DriveError.providerUnavailable(platform) }
            var value = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            if platform == .pan115 { value = Pan115Constants.filterLoginCookies(value) }
            if platform == .xunlei {
                // Anything captured or pasted came from the web client, which refreshes differently.
                guard let parsed = XunleiCredential.parseWebLogin(value) else { throw YunXLoginError.rejected }
                value = parsed.driveCredential.value
            }
            try await save(DriveCredential(value), platform: platform, provider: provider, extra: extra, requireVerified: requireVerified)
        case let .video(platform):
            guard let parser = parsers.of(platform) else { throw YunXLoginError.rejected }
            let cookie = secret.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let nickname = try await parser.validateCookie(cookie) else { throw YunXLoginError.rejected }
            try vault.add(platform: target.platform, fields: ["cookie": cookie, "nickname": nickname, "remark": ""], key: "cookie")
        }
        reloadAccounts()
    }

    private func save(_ credential: DriveCredential, platform: DrivePlatform, provider: any CloudDriveProvider, extra: [String: String], requireVerified: Bool = false) async throws {
        guard provider.isWellFormed(credential: credential) else { throw YunXLoginError.rejected }
        var nickname = extra["nickname"] ?? ""
        switch await provider.accountState(credential: credential) {
        case .signedOut: throw YunXLoginError.rejected
        case .unverified: if requireVerified { throw YunXLoginError.rejected }
        case let .signedIn(name): nickname = name
        }
        var fields = YunXCredentialCodec.fields(platform, credential: credential, base: extra)
        fields["nickname"] = nickname
        try vault.add(platform: platform.rawValue, fields: fields, key: YunXBackupStore.key(platform.rawValue))
    }

    func sendSms(_ platform: DrivePlatform, phone: String) async throws -> YunXSmsChallenge {
        try await sendSms(platform, phone: phone, device: .generate())
    }

    private func sendSms(_ platform: DrivePlatform, phone: String, device: XunleiDevice) async throws -> YunXSmsChallenge {
        switch platform {
        case .xunlei:
            let step = try await xunlei.sendSMS(mobile: phone, device: device)
            guard !step.smsCreditKey.isEmpty else { throw DriveError.api(message: step.message) }
            return .xunlei(creditKey: step.smsCreditKey, token: step.smsToken, device: device)
        case .guangya:
            guard let provider = provider(.guangya) as? GuangYaProvider else { throw DriveError.providerUnavailable(.guangya) }
            let device = GuangYaDevice.make()
            return .guangya(try await provider.sendSmsCode(phoneNumber: phone, device: device), device)
        default: throw YunXLoginError.rejected
        }
    }

    func smsLogin(phone: String, code: String, challenge: YunXSmsChallenge) async throws {
        switch challenge {
        case let .xunlei(creditKey, token, device):
            let step = try await xunlei.smsLogin(mobile: phone, smsCode: code, creditKey: creditKey, smsToken: token, device: device)
            try await finishXunlei(step, username: phone, device: device)
        case let .guangya(sent, device):
            guard let provider = provider(.guangya) as? GuangYaProvider else { throw DriveError.providerUnavailable(.guangya) }
            let credential = try await provider.smsLogin(phoneNumber: phone, verificationId: sent.verificationId, code: code,
                                                         isUser: sent.isUser, device: device)
            try await save(credential, platform: .guangya, provider: provider, extra: ["account": phone])
            reloadAccounts()
        }
    }

    /// Same order as YunX: login, captcha init, token.
    private func finishXunlei(_ step: XunleiLoginStep, username: String, device: XunleiDevice) async throws {
        guard !step.sessionId.isEmpty else { throw step.message.isEmpty ? YunXLoginError.rejected : DriveError.api(message: step.message) }
        guard let provider = provider(.xunlei) else { throw DriveError.providerUnavailable(.xunlei) }
        let captcha = await xunlei.initCaptcha(device: device, username: username) ?? ""
        guard let tokens = await xunlei.exchangeToken(sessionId: step.sessionId, device: device, captchaToken: captcha) else {
            throw YunXLoginError.rejected
        }
        let credential = XunleiCredential(accessToken: tokens.accessToken, refreshToken: tokens.refreshToken, deviceId: device.deviceId,
                                          captchaToken: captcha, userId: step.userId, nickname: step.nickname, authType: "")
        try await save(credential.driveCredential, platform: .xunlei, provider: provider, extra: ["account": username, "nickname": step.nickname])
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

    /// What a resolve should use now. An opened share keeps its session, because file tokens are bound
    /// to its stoken, but the account comes from the vault each time, as YunX's `currentCredential()`
    /// does: one added after opening must not leave the download on the guest path. An unreadable
    /// vault keeps what the source had.
    private func current(_ source: Source) async -> Source {
        switch source {
        case let .share(provider, session, _):
            guard (try? vault.accounts()) != nil else { return source }
            return .share(provider, session, await credential(provider.platform, provider: provider))
        case let .drive(provider, held):
            return .drive(provider, await credential(provider.platform, provider: provider) ?? held)
        }
    }

    // MARK: Background refresh

    /// Starts with the page rather than the app, so the Keychain is not touched until it is wanted.
    func startBackgroundRefresh() {
        guard refresher == nil else { return }
        refresher = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAccounts()
                try? await Task.sleep(for: Self.refreshTick)
            }
        }
    }

    /// Rotates sessions that are due on every account, not only the active one, and fills in missing
    /// names. A failure leaves the old credential and waits before asking that drive again.
    func refreshAccounts(now: Date = Date()) async {
        guard let all = try? vault.accounts() else { return }
        var changed = false
        for account in all {
            guard let platform = account.drivePlatform, let provider = provider(platform) else { continue }
            if let wait = retryAfter[account.id], wait > now { continue }
            let credential = YunXCredentialCodec.credential(platform, fields: account.fields)
            var failed = false
            if let interval = provider.credentialRefreshInterval, now.timeIntervalSince1970 * 1000 - Double(account.updatedAt) > interval * 1000 {
                if let fresh = await provider.refreshCredential(credential) {
                    try? vault.rotate(previous: credential, updated: fresh)
                    changed = true
                } else { failed = true }
            }
            if account.nickname.isEmpty {
                if case let .signedIn(name) = await provider.accountState(credential: credential), !name.isEmpty {
                    try? vault.setNickname(id: account.id, name)
                    changed = true
                } else { failed = true }
            }
            retryAfter[account.id] = failed ? now.addingTimeInterval(Self.refreshRetry) : nil
        }
        if changed { reloadAccounts() }
    }

    // MARK: Settings

    private func settingsChanged(from old: YunXSettings) {
        guard settings != old else { return }
        limit.value = settings.speedLimitBytes
        do { try settingsStore.save(settings, previous: old) } catch { self.error = error.localizedDescription }
        guard settings.gopeed != old.gopeed || settings.p2pMaxRunning != old.p2pMaxRunning, let gopeed else { return }
        let current = settings
        Task { _ = try? await gopeed.applyRuntimeConfig(maxRunning: current.p2pMaxRunning, settings: current.gopeed) }
    }

    var saveDirectoryLabel: String { saveDirectory().path }

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
        source = nil; files = []; path = []; browsing = false; selected = []; video = nil; videoLink = nil; error = nil; notice = nil; savePicker = nil; shareLink = nil
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

    /// A link from the clipboard prompt. A running open keeps going; the link waits in the field.
    func openCopied(_ link: String, passcode: String?) async {
        self.link = link
        self.passcode = passcode ?? ""
        guard !busy else { return }
        await open()
    }

    private func openShare(_ parsed: ParsedShareLink) async throws {
        let (link, provider) = try drives.router.route(self.link)
        let credential = await credential(parsed.platform, provider: provider)
        if credential == nil, !provider.capabilities.contains(.guestShareAccess) { throw DriveError.loginRequired }
        let code = passcode.trimmingCharacters(in: .whitespaces)
        let session: ShareSession
        do {
            session = try await provider.openShare(link, passcode: code.isEmpty ? link.passcode : code, credential: credential)
        } catch {
            if link.passcode == nil { passcodeAsked = true }
            throw error
        }
        source = .share(provider, session, credential)
        shareLink = (link, code.isEmpty ? (link.passcode ?? "") : code)
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

    #if DEBUG
    func loadVideoForTesting(_ result: VideoParseResult) { video = result }
    func loadPageForTesting(files: [DriveFile] = [], path: [String] = [], jobs: [YunXJob] = [], accounts: [YunXAccount] = []) {
        self.files = files
        self.path = path.map { ("", $0) }
        browsing = !path.isEmpty
        self.jobs = jobs
        self.accounts = accounts
    }
    #endif

    func selectQuality(_ qn: Int) async {
        guard let videoLink else { return }
        await working { try await openVideo(videoLink, qn: qn) }
    }

    // MARK: Downloads

    private func saveDirectory() -> URL { DownloadSaver.resolveSaveDirectory(custom: settings.saveDirectory) }

    private func downloadEngine() throws -> DownloadEngine {
        if let engine { return engine }
        let box = limit
        let made = try makeEngine(DownloadConfiguration(speedLimiter: DownloadSpeedLimiter(limit: { box.value })))
        engine = made
        return made
    }

    private func update(_ id: UUID, _ change: (inout YunXJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[index])
    }

    var jobGroups: [YunXJobGroup] { YunXJobGroup.make(jobs, globalRoot: saveDirectory().path) }

    private func leafName(_ relative: String) -> String { relative.split(separator: "/").last.map(String.init) ?? relative }

    /// Adds the job, or takes over one restored after a restart, and runs `body`. HTTP jobs wait for a free slot.
    private func launch(id: UUID = UUID(), name: String, directory: URL, usesSlot: Bool = true, body: @escaping @MainActor (UUID) async throws -> URL) {
        if jobs.contains(where: { $0.id == id }) {
            update(id) { $0.state = .queued; $0.received = 0; $0.speed = 0 }
            jobStore.update(id) { $0.failure = nil }
        } else {
            jobs.insert(YunXJob(id: id, name: leafName(name), relativeName: name, saveDirectory: directory.path, usesSlot: usesSlot, state: .queued), at: 0)
        }
        runners[id] = Task { [weak self] in
            do {
                while let self, usesSlot, self.jobs.filter({ $0.usesSlot && $0.state == .running }).count >= Self.maxTransfers {
                    try await Task.sleep(for: .milliseconds(100))
                }
                self?.update(id) { $0.state = .running }
                let url = try await body(id)
                self?.update(id) { $0.state = .finished(url); $0.savedPath = url.path }
                self?.jobStore.remove(id)
            } catch is CancellationError {
                self?.cancelled(id)
            } catch DownloadError.cancelled {
                self?.cancelled(id)
            } catch {
                // The record stays, so the partial file can be picked up after a restart.
                let message = error.localizedDescription
                self?.jobStore.update(id) { $0.failure = message }
                let saved = self?.jobStore.load().contains { $0.id == id } ?? false
                self?.update(id) { $0.state = .failed(message); $0.canRetry = saved }
            }
            self?.tasks[id] = nil
            self?.runners[id] = nil
            self?.p2pTasks[id] = nil
        }
    }

    private func cancelled(_ id: UUID) {
        update(id) { $0.state = .cancelled }
        jobStore.remove(id)
    }

    /// Runs one transfer under a job and returns where it landed. `restoring` continues a saved task.
    private func fetch(_ id: UUID, url: URL, headers: [String: String], to destination: URL, refresh: LinkRefresher? = nil, restoring: UUID? = nil) async throws -> URL {
        let engine = try downloadEngine()
        let task: DownloadTask
        if let restoring, let saved = try? engine.restore(id: restoring, url: url, headers: headers, refreshLink: refresh) {
            task = saved
        } else {
            task = try engine.makeTask(DownloadRequest(url: url, destination: destination, headers: headers, refreshLink: refresh))
        }
        tasks[id] = task
        jobStore.update(id) { $0.taskId = task.id }
        update(id) { $0.canPause = true }
        let watcher = Task { [weak self] in
            // Every published change redraws the page; four a second reads as live.
            var shown = ContinuousClock.now - .seconds(1), phase: DownloadPhase?
            for await progress in task.progress {
                let now = ContinuousClock.now
                guard now - shown >= .milliseconds(250) || progress.phase != phase || progress.receivedBytes == progress.totalBytes else { continue }
                shown = now; phase = progress.phase
                self?.update(id) { job in
                    job.received = progress.receivedBytes
                    job.total = progress.totalBytes
                    job.speed = progress.bytesPerSecond
                    // A last buffered event can arrive after the job finished.
                    if job.state.isActive { job.state = progress.phase == .paused ? .paused : .running }
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

    /// HLS goes through its own downloader, so the speed limit is applied in the byte callback.
    private func fetchHLS(_ id: UUID, url: String, headers: [String: String], to destination: URL) async throws -> URL {
        let box = YunXCounter()
        let bytesLimit = limit
        let limiter = DownloadSpeedLimiter(limit: { bytesLimit.value })
        return try await HlsDownloader().download(url: url, headers: headers, destination: destination) { [weak self] bytes in
            try? await limiter.acquire(bytes)
            let total = box.add(bytes)
            await self?.update(id) { $0.received = total }
        }
    }

    /// Downloads the ticked items, or just `only`. Folders are walked first, then each file is one job.
    func downloadSelected(only: DriveFile? = nil) {
        guard let source else { return }
        let picked = only.map { [$0] } ?? files.filter { selected.contains($0.id) }
        selected = []
        let share = shareLink
        for file in picked where !file.isDirectory { download(file, name: file.name, source: source, share: share) }
        let folders = picked.filter(\.isDirectory)
        guard !folders.isEmpty else { return }
        Task {
            await working {
                for folder in folders {
                    let found = try await YunXFolderWalker.walk(folder) { id in try await Self.list(source, directory: id) }
                    for item in found { download(item.file, name: item.name, source: source, share: share) }
                }
            }
        }
    }

    private nonisolated static func list(_ source: Source, directory: String?) async throws -> [DriveFile] {
        switch source {
        case let .share(provider, session, credential):
            return try await provider.listShareFiles(session: session, directoryId: directory, credential: credential)
        case let .drive(provider, credential):
            return try await provider.listFiles(directoryId: directory, credential: credential)
        }
    }

    private func download(_ file: DriveFile, name: String, source: Source, share: (link: ParsedShareLink, passcode: String)?) {
        let directory = saveDirectory()
        let id = UUID()
        var record = YunXJobRecord(id: id, kind: .drive, name: name, saveDirectory: directory.path, fileId: file.id, fileName: file.name,
                                   fileSize: file.size, parentId: file.parentId, fileToken: file.fileToken)
        switch source {
        case let .share(provider, _, _):
            record.kind = .share
            record.platform = provider.platform.rawValue
            record.shareId = share?.link.shareId ?? ""
            record.passcode = share?.passcode ?? ""
        case let .drive(provider, _): record.platform = provider.platform.rawValue
        }
        jobStore.put(record)
        launch(id: id, name: name, directory: directory) { [weak self] id in
            guard let self else { throw CancellationError() }
            return try await self.transfer(id, file: file, name: name, source: source, directory: directory, restoring: nil)
        }
    }

    private func transfer(_ id: UUID, file: DriveFile, name: String, source opened: Source, directory: URL, restoring: UUID?) async throws -> URL {
        let source = await current(opened)
        let cleanups = YunXCleanups()
        let resolve: @Sendable () async throws -> ResolvedLink = {
            let link = try await Self.resolve(file, source: source)
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
            let folders = name.split(separator: "/").dropLast().joined(separator: "/")
            let leaf = DownloadPathPolicy.sanitizeName(link.filename.isEmpty ? file.name : link.filename)
            let destination = try DownloadSaver.destination(for: folders.isEmpty ? leaf : "\(folders)/\(leaf)", in: directory)
            let saved: URL
            if link.isHLS {
                saved = try await fetchHLS(id, url: link.url.absoluteString, headers: link.headers, to: destination)
            } else {
                saved = try await fetch(id, url: link.url, headers: link.headers, to: destination, refresh: { _ in
                    let fresh = try await resolve()
                    return RefreshedLink(url: fresh.url, headers: fresh.headers)
                }, restoring: restoring)
            }
            await finish()
            return saved
        } catch {
            await finish()
            throw error
        }
    }

    private nonisolated static func resolve(_ file: DriveFile, source: Source) async throws -> ResolvedLink {
        switch source {
        case let .share(provider, session, credential):
            return try await provider.resolveShareFile(session: session, file: file, credential: credential, options: ShareResolveOptions())
        case let .drive(provider, credential):
            return try await provider.resolveFile(file, credential: credential)
        }
    }

    func download(_ media: VideoMedia) {
        guard let title = video?.title else { return }
        let separate = !media.isHls && !media.audioUrl.isEmpty
        if separate, !skipFfmpeg, let root = try? toolsRoot(), !FfmpegProvisioner(root: root).isInstalled {
            pendingFfmpeg = media
            return
        }
        let name = Self.fileName(media, title: title)
        let directory = saveDirectory()
        let refreshVideo = refresher(for: media)
        launch(name: name, directory: directory) { [weak self] id in
            guard let self else { throw CancellationError() }
            let destination = try DownloadSaver.destination(for: name, in: directory)
            if media.isHls { return try await fetchHLS(id, url: media.url, headers: media.headers, to: destination) }
            guard let url = URL(string: media.url) else { throw VideoParseException(.unknown, "") }
            guard !media.audioUrl.isEmpty, let audio = URL(string: media.audioUrl) else {
                return try await fetch(id, url: url, headers: media.headers, to: destination, refresh: refreshVideo(false))
            }
            // Separate tracks: fetch both into a private folder, mux, then publish.
            let root = try toolsRoot()
            let work = try root.makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: work) }
            let videoFile = try await fetch(id, url: url, headers: media.headers, to: work.appendingPathComponent("video.m4s"), refresh: refreshVideo(false))
            let audioFile = try await fetch(id, url: audio, headers: media.audioHeaders, to: work.appendingPathComponent("audio.m4s"), refresh: refreshVideo(true))
            let muxed = work.appendingPathComponent("muxed.mp4")
            guard await MediaMuxer(ffmpeg: FfmpegMuxer(root: root)).mux(video: videoFile, audio: audioFile, out: muxed) else {
                throw YunXLoginError.muxFailed
            }
            return try DownloadSaver.save(muxed, as: name, in: directory)
        }
    }

    /// Parses the page again and takes the media at the same position, as video links expire quickly.
    private func refresher(for media: VideoMedia) -> (Bool) -> LinkRefresher? {
        guard let detected = videoLink, let index = video?.medias.firstIndex(where: { $0.url == media.url }) else { return { _ in nil } }
        let qn = video?.selectedQn
        return { audio in
            { [weak self] _ in try await self?.freshLink(detected, qn: qn, index: index, audio: audio) }
        }
    }

    private func freshLink(_ detected: DetectedVideoLink, qn: Int?, index: Int, audio: Bool) async throws -> RefreshedLink? {
        guard let parser = parsers.of(detected.platform) else { return nil }
        let cookie = (try? vault.active(YunXAccount.videoPrefix + detected.platform.rawValue))?.fields["cookie"] ?? ""
        let parsed: VideoParseResult
        if let qn, let selectable = parser as? any QualitySelectableParser {
            parsed = try await selectable.parseWithQuality(detected, cookie: cookie, qn: qn)
        } else {
            parsed = try await parser.parse(detected, cookie: cookie)
        }
        guard parsed.medias.indices.contains(index) else { return nil }
        let media = parsed.medias[index]
        guard let url = URL(string: audio ? media.audioUrl : media.url) else { return nil }
        return RefreshedLink(url: url, headers: audio ? media.audioHeaders : media.headers)
    }

    /// Fetches FFmpeg after the page has asked, then starts the download that was waiting for it.
    func installFfmpeg() async {
        guard let media = pendingFfmpeg else { return }
        pendingFfmpeg = nil
        installingFfmpeg = true
        defer { installingFfmpeg = false }
        do {
            _ = try await FfmpegProvisioner(root: try toolsRoot()).provision()
            download(media)
        } catch { self.error = error.localizedDescription }
    }

    /// Declined: the built-in muxer handles fragmented MP4 for the rest of this run.
    func declineFfmpeg() {
        guard let media = pendingFfmpeg else { return }
        pendingFfmpeg = nil
        skipFfmpeg = true
        download(media)
    }

    // MARK: Save to drive

    var canSaveToDrive: Bool {
        guard case let .share(provider, _, held)? = source else { return false }
        return (held != nil || !accounts(for: provider.platform.rawValue).isEmpty) && provider.capabilities.contains(.saveToDrive)
    }

    func beginSave(only: DriveFile? = nil) async {
        guard canSaveToDrive, let opened = source else { return }
        let refreshed = await current(opened)
        source = refreshed
        guard case let .share(provider, _, _?) = refreshed else { return }
        let items = only.map { [$0] } ?? files.filter { selected.contains($0.id) }
        guard !items.isEmpty else { return }
        savePicker = YunXSavePicker(items: items, trail: [("", YunXNames.drive(provider.platform))])
        await listPicker(nil)
    }

    /// A drive that cannot list its folders can still save to the root.
    private func listPicker(_ directory: String?) async {
        guard case let .share(provider, _, credential?)? = source else { return }
        let found = (try? await provider.listFiles(directoryId: directory, credential: credential)) ?? []
        savePicker?.folders = found.filter(\.isDirectory)
    }

    func pickerEnter(_ folder: DriveFile) async {
        savePicker?.trail.append((folder.id, folder.name))
        await listPicker(folder.id)
    }

    func pickerUp(to index: Int) async {
        guard let trail = savePicker?.trail, trail.indices.contains(index) else { return }
        savePicker?.trail = Array(trail.prefix(index + 1))
        await listPicker(index == 0 ? nil : trail[index].id)
    }

    func confirmSave() async {
        guard let picker = savePicker, case let .share(provider, session, credential?)? = source else { return }
        savePicker = nil
        selected = []
        let target = picker.trail.count > 1 ? picker.trail.last?.id : nil
        await working {
            for item in picker.items {
                _ = try await provider.saveToDrive(session: session, file: item, directoryId: target, credential: credential, skipSpaceCheck: false)
            }
            notice = tr("Saved %1$@ items to the drive.", String(picker.items.count))
        }
    }

    // MARK: Preview

    func previewable(_ file: DriveFile) -> Bool { !file.isDirectory && MediaPreview.kind(of: URL(fileURLWithPath: file.name)) != nil }
    /// A video-only DASH track would play silently, so only combined media are offered.
    func previewable(_ media: VideoMedia) -> Bool { media.kind == .video && media.audioUrl.isEmpty }

    func preview(_ file: DriveFile) async {
        guard let opened = source else { return }
        await working {
            let source = await current(opened)
            let link = try await Self.resolve(file, source: source)
            if let directory = link.cleanupDirectoryId {
                previewCleanup = {
                    if case let .share(provider, _, credential?) = source { await provider.cleanup(directoryId: directory, credential: credential) }
                    if case let .drive(provider, credential) = source { await provider.cleanup(directoryId: directory, credential: credential) }
                }
            }
            try show(link.url, headers: link.headers, name: link.isHLS ? "\(file.name).m3u8" : file.name, title: file.name)
        }
    }

    func preview(_ media: VideoMedia) async {
        await working {
            guard let url = URL(string: media.url) else { throw VideoParseException(.unknown, "") }
            let title = Self.fileName(media, title: video?.title ?? "")
            try show(url, headers: media.headers, name: media.isHls ? "\(title).m3u8" : title, title: title)
        }
    }

    private func show(_ url: URL, headers: [String: String], name: String, title: String) throws {
        guard let player = MediaPreview.makePlayer(url: url, headers: headers, fileName: name) else { throw YunXLoginError.noPreview }
        preview = YunXPreview(title: title, player: player)
    }

    func closePreview() {
        preview?.player.pause()
        preview = nil
        if let cleanup = previewCleanup {
            previewCleanup = nil
            Task { await cleanup() }
        }
    }

    // MARK: Restoring

    /// Lists what the last run left unfinished, paused. Nothing restarts or touches the network
    /// until Resume, when the current account resolves a new link.
    func restoreJobs() {
        guard !restored else { return }
        restored = true
        let store = downloadStore ?? (try? DownloadStore(root: DownloadStore.defaultRoot()))
        let saved = store?.list() ?? []
        for record in jobStore.load() where !jobs.contains(where: { $0.id == record.id }) {
            let state = saved.first { $0.id == record.taskId }
            var job = YunXJob(id: record.id, name: leafName(record.name), relativeName: record.name, saveDirectory: record.saveDirectory,
                              usesSlot: record.kind != .p2p, state: Self.restoredState(record, hasProgress: state != nil))
            job.canRetry = true
            job.received = state.map { store?.receivedBytes($0) ?? 0 } ?? 0
            job.total = state?.size ?? (record.fileSize > 0 ? record.fileSize : nil)
            jobs.append(job)
        }
    }

    /// Only a transfer that really began reads as paused; a job with no progress never did.
    nonisolated static func restoredState(_ record: YunXJobRecord, hasProgress: Bool) -> YunXJob.State {
        if let failure = record.failure { return .failed(failure) }
        return hasProgress || record.kind == .p2p ? .paused : .notStarted
    }

    private func continueRecord(_ record: YunXJobRecord) {
        let directory = URL(fileURLWithPath: record.saveDirectory, isDirectory: true)
        if record.kind == .p2p {
            guard let engine = try? p2pEngine() else { return }
            runP2P(id: record.id, url: record.p2pURL, name: record.name, engine: engine, directory: directory,
                   select: record.selectFiles, existing: record.gopeedTask)
            return
        }
        launch(id: record.id, name: record.name, directory: directory) { [weak self] id in
            guard let self else { throw CancellationError() }
            let source = try await self.source(for: record)
            let file = await self.currentFile(record, source: source)
            return try await self.transfer(id, file: file, name: record.name, source: source, directory: directory, restoring: record.taskId)
        }
    }

    /// A share's file tokens belong to the session that listed them, so a reopened share lists again.
    private func currentFile(_ record: YunXJobRecord, source: Source) async -> DriveFile {
        guard case let .share(provider, session, credential) = source,
              let listed = try? await provider.listShareFiles(session: session, directoryId: record.parentId.isEmpty ? nil : record.parentId, credential: credential),
              let fresh = listed.first(where: { $0.id == record.fileId }) else { return record.file }
        return fresh
    }

    private func source(for record: YunXJobRecord) async throws -> Source {
        guard let platform = DrivePlatform(rawValue: record.platform), let provider = provider(platform) else { throw YunXLoginError.rejected }
        let credential = await credential(platform, provider: provider)
        guard record.kind == .share else {
            guard let credential else { throw DriveError.loginRequired }
            return .drive(provider, credential)
        }
        if credential == nil, !provider.capabilities.contains(.guestShareAccess) { throw DriveError.loginRequired }
        let passcode = record.passcode.isEmpty ? nil : record.passcode
        let session = try await provider.openShare(ParsedShareLink(shareId: record.shareId, passcode: passcode, platform: platform),
                                                   passcode: passcode, credential: credential)
        return .share(provider, session, credential)
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

    func pause(_ job: YunXJob) {
        Task {
            if let task = p2pTasks[job.id], let gopeed { try? await gopeed.pauseTask(task) } else { await tasks[job.id]?.pause() }
            update(job.id) { $0.state = .paused }
        }
    }

    func resume(_ job: YunXJob) {
        if runners[job.id] == nil, let record = jobStore.load().first(where: { $0.id == job.id }) {
            continueRecord(record)
            return
        }
        Task {
            if let task = p2pTasks[job.id], let gopeed { try? await gopeed.continueTask(task) } else { await tasks[job.id]?.start() }
            update(job.id) { $0.state = .running }
        }
    }

    func cancel(_ job: YunXJob) {
        if let runner = runners[job.id] { runner.cancel(); return }
        // A job restored from the last run has nothing running yet.
        forget(job)
        update(job.id) { $0.state = .cancelled }
    }

    private func forget(_ job: YunXJob) {
        let record = jobStore.load().first { $0.id == job.id }
        if let task = record?.taskId,
           let store = downloadStore ?? (try? DownloadStore(root: DownloadStore.defaultRoot())) { store.remove(id: task) }
        if let task = record?.gopeedTask, !task.isEmpty, let engine = try? p2pEngine() {
            let keepRunning = p2pRunning(except: job.id)
            Task { [weak self] in
                // The kernel is down after a restart, and only it can drop the URL from its store.
                guard await engine.isInstalled else { return }
                try? await self?.ensureCurrentKernel(engine)
                _ = try? await engine.start()
                await Self.retire(task, engine: engine, keepRunning: keepRunning)
            }
        }
        jobStore.remove(job.id)
    }

    func clearFinished() {
        for job in jobs where !job.state.isActive { forget(job) }
        jobs.removeAll { !$0.state.isActive }
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    // MARK: P2P through Gopeed

    private func p2pEngine() throws -> GopeedEngine {
        if let gopeed { return gopeed }
        let made = GopeedEngine(root: try toolsRoot())
        gopeed = made
        return made
    }

    /// A local `.torrent`; Gopeed opens the path itself.
    func openTorrent(_ url: URL) async {
        await working { await addP2P(url.path) }
    }

    private func addP2P(_ url: String) async {
        do {
            let engine = try p2pEngine()
            guard await engine.isInstalled else { pendingP2P = url; return }
            await prepareP2P(url, engine: engine)
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
            _ = try await GopeedKernelProvisioner(root: try toolsRoot()).provision(engine: engine)
            await prepareP2P(url, engine: engine)
        } catch { self.error = error.localizedDescription }
    }

    /// A kernel from an older pin is replaced here, before anything can launch it.
    private func ensureCurrentKernel(_ engine: GopeedEngine) async throws {
        guard await engine.needsReprovision else { return }
        _ = try await GopeedKernelProvisioner(root: try toolsRoot()).provision(engine: engine)
    }

    private func applyP2PSettings(_ engine: GopeedEngine) async throws {
        try await ensureCurrentKernel(engine)
        _ = try await engine.start()
        _ = try await engine.applyRuntimeConfig(maxRunning: settings.p2pMaxRunning, settings: settings.gopeed)
    }

    /// Offers the file list when there is one. A magnet with no peers yet cannot list, so a failed
    /// resolve starts the whole torrent, which is what happened before picking existed.
    private func prepareP2P(_ url: String, engine: GopeedEngine) async {
        do {
            try await applyP2PSettings(engine)
            if let resolved = try? await engine.resolve(url: url), resolved.files.count > 1 {
                torrentPick = YunXTorrentPick(url: url, name: resolved.name, files: resolved.files, selected: Set(resolved.files.indices))
                return
            }
            startP2P(url, engine: engine, select: [])
        } catch { self.error = error.localizedDescription }
    }

    /// Gopeed was started only to list the torrent, so with no job on it, it stops again.
    func cancelTorrent() {
        guard torrentPick != nil else { return }
        torrentPick = nil
        guard let gopeed else { return }
        Task { [weak self] in
            guard let self, !(await gopeed.hasActiveTasks()) else { return }
            // Checked after the await, so a torrent added meanwhile keeps its kernel.
            guard !self.p2pRunning(except: nil), self.torrentPick == nil else { return }
            await gopeed.stop()
        }
    }

    /// Whether a live job is polling Gopeed, which stopping would fail, even while it is paused.
    private func p2pRunning(except id: UUID?) -> Bool {
        jobs.contains { !$0.usesSlot && $0.id != id && runners[$0.id] != nil }
    }

    func confirmTorrent() {
        guard let pick = torrentPick, !pick.selected.isEmpty, let gopeed else { return }
        torrentPick = nil
        startP2P(pick.url, engine: gopeed, select: pick.selection)
    }

    private func startP2P(_ url: String, engine: GopeedEngine, select: [Int]) {
        let directory = saveDirectory()
        let id = UUID()
        let name = P2PLink.displayName(url)
        jobStore.put(YunXJobRecord(id: id, kind: .p2p, name: name, saveDirectory: directory.path, p2pURL: url, selectFiles: select))
        runP2P(id: id, url: url, name: name, engine: engine, directory: directory, select: select, existing: "")
    }

    /// `existing` is the Gopeed task from an earlier run; its store outlives the app, so it continues there.
    private func runP2P(id: UUID, url: String, name: String, engine: GopeedEngine, directory: URL, select: [Int], existing: String) {
        launch(id: id, name: name, directory: directory, usesSlot: false) { [weak self] id in
            try await self?.applyP2PSettings(engine)
            let task: String
            var reused = false
            if !existing.isEmpty, (try? await engine.taskStatus(existing)) != nil { reused = true }
            if reused {
                task = existing
            } else {
                // Passkey trackers go with the task, so they leave Gopeed's store when it is retired.
                let trackers = GopeedTrackers.perTask(self?.settings.gopeed.trackers ?? [])
                task = try await engine.createTask(url: url, saveDir: directory.path, fileName: "", trackers: trackers, selectFiles: select)
            }
            self?.p2pTasks[id] = task
            self?.jobStore.update(id) { $0.gopeedTask = task }
            self?.update(id) { $0.canPause = true }
            do {
                if reused { try await engine.continueTask(task) }
                while true {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    let view = try await engine.taskStatus(task)
                    self?.update(id) {
                        $0.received = view.downloaded
                        $0.total = view.total > 0 ? view.total : nil
                        $0.speed = Double(view.speed)
                        $0.state = view.status == GopeedEngine.TaskStatus.pause ? .paused : .running
                    }
                    if view.status == GopeedEngine.TaskStatus.done { break }
                    if view.status == GopeedEngine.TaskStatus.error {
                        throw DriveError.api(message: await engine.taskError(task) ?? tr("The download failed."))
                    }
                }
                // Gopeed wrote these, so `DownloadFinalizer.publish` never saw them.
                for file in try await engine.taskOutputFiles(task) { DownloadQuarantine.mark(file) }
            } catch {
                self?.jobStore.update(id) { $0.gopeedTask = "" }
                await Self.retire(task, engine: engine, keepRunning: self?.p2pRunning(except: id) == true)
                throw error
            }
            await Self.retire(task, engine: engine, keepRunning: self?.p2pRunning(except: id) == true)
            return directory
        }
    }

    /// Removes the task, which keeps its files, so its URL leaves Gopeed's store. Runs in its own
    /// task because a cancelled caller would cancel these requests too.
    private nonisolated static func retire(_ task: String, engine: GopeedEngine, keepRunning: Bool) async {
        await Task {
            try? await engine.deleteTask(task)
            guard !keepRunning else { return }
            if !(await engine.hasActiveTasks()) { await engine.stop() }
        }.value
    }

    /// Called on app termination, which cannot wait for async work, so this blocks for at most a
    /// moment longer than the engine's own stop escalation.
    func shutdown() {
        refresher?.cancel()
        guard let gopeed else { return }
        let stopped = DispatchSemaphore(value: 0)
        Task.detached {
            await gopeed.stop()
            stopped.signal()
        }
        _ = stopped.wait(timeout: .now() + 4)
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
    case rejected, muxFailed, folderTooLarge, noPreview
    var errorDescription: String? {
        switch self {
        case .rejected: return tr("That login was not accepted. Sign in again.")
        case .muxFailed: return tr("Could not merge the video and audio tracks.")
        case .folderTooLarge: return tr("This folder is too large or too deep to download at once.")
        case .noPreview: return tr("This format cannot be previewed.")
        }
    }
}
