import AppKit
import CloudDriveKit
import DownloadKit
@testable import MediaToolsKit
import ThermoL10n
import VideoKit
import XCTest
@testable import ThermoApp

private class MemoryBackend: YunXSecretBackend, @unchecked Sendable {
    var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}

final class YunXDownloadTests: XCTestCase {
    private func vault() -> YunXVault { YunXVault(backend: MemoryBackend(), now: { 1 }) }

    func testClassifiesEachLinkKind() {
        XCTAssertEqual(YunXLink.classify(" magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567 "),
                       .p2p("magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567"))
        guard case let .share(link)? = YunXLink.classify("https://pan.quark.cn/s/abc123 提取码：a1b2") else { return XCTFail("share") }
        XCTAssertEqual(link.platform, .quark)
        XCTAssertEqual(link.passcode, "a1b2")
        guard case let .video(video)? = YunXLink.classify("https://www.bilibili.com/video/BV1xx411c7mD") else { return XCTFail("video") }
        XCTAssertEqual(video.platform, .bilibili)
        XCTAssertNil(YunXLink.classify("not a link"))
    }

    func testCookieDetectionNeedsAllRequiredKeysOrOneAlternative() {
        let domains = [".10086.cn"]
        let partial = [(domain: ".10086.cn", name: "RMKEY", value: "1")]
        XCTAssertNil(YunXLoginMethod.detect(partial, domains: domains, required: ["Os_SSo_Sid", "RMKEY"], anyOf: []))
        XCTAssertEqual(YunXLoginMethod.detect(partial + [(".10086.cn", "authorization", "2"), (".other.cn", "x", "3")],
                                              domains: domains, required: ["Os_SSo_Sid", "RMKEY"], anyOf: ["authorization"]),
                       "RMKEY=1; authorization=2")
    }

    func testAccountsAreSeparatePerLoginAndPrimaryMoves() throws {
        let vault = vault()
        let first = try vault.add(platform: "quark", fields: ["cookie": "a", "nickname": "one"], key: "cookie")
        let second = try vault.add(platform: "quark", fields: ["cookie": "b", "nickname": "two"], key: "cookie")
        XCTAssertEqual(try vault.accounts().count, 2)
        XCTAssertEqual(try vault.active("quark")?.id, first.id)
        try vault.setPrimary(id: second.id)
        XCTAssertEqual(try vault.active("quark")?.id, second.id)
        try vault.remove(id: second.id)
        XCTAssertEqual(try vault.active("quark")?.id, first.id)
        try vault.add(platform: "quark", fields: ["cookie": "a2", "nickname": "one"], key: "cookie")
        XCTAssertEqual(try vault.accounts().map { $0.fields["cookie"] }, ["a2"])
    }

    func testRotationUpdatesTheMatchingAccountOnly() throws {
        let vault = vault()
        try vault.add(platform: "quark", fields: ["cookie": "a"], key: "cookie")
        try vault.add(platform: "uc", fields: ["cookie": "b"], key: "cookie")
        try vault.rotate(previous: DriveCredential("b"), updated: DriveCredential("c"))
        XCTAssertEqual(try vault.active("uc")?.fields["cookie"], "c")
        XCTAssertEqual(try vault.active("quark")?.fields["cookie"], "a")
    }

    func testStructuredCredentialsSurviveTheFieldMapping() {
        let xunlei = XunleiCredential(accessToken: "token.abc", refreshToken: "refresh", deviceId: "device", authType: "x").driveCredential
        let xunleiFields = YunXCredentialCodec.fields(.xunlei, credential: xunlei)
        XCTAssertEqual(XunleiCredential(YunXCredentialCodec.credential(.xunlei, fields: xunleiFields))?.refreshToken,
                       XunleiCredential(xunlei)?.refreshToken)
        let guangya = GuangYaCredential(accessToken: "a", refreshToken: "r", device: GuangYaDevice(deviceId: "d", deviceSign: "s"), accessExpiresAt: 9)
        let fields = YunXCredentialCodec.fields(.guangya, credential: guangya.driveCredential)
        XCTAssertEqual(GuangYaCredential(YunXCredentialCodec.credential(.guangya, fields: fields)), guangya)
    }

    func testEncryptedBackupRoundTripKeepsEveryAccount() async throws {
        let source = vault()
        try source.add(platform: "quark", fields: ["cookie": "__pus=secret-value", "nickname": "one"], key: "cookie")
        try source.add(platform: "quark", fields: ["cookie": "__pus=other", "nickname": "two"], key: "cookie")
        try source.add(platform: "video:BILIBILI", fields: ["cookie": "SESSDATA=1", "nickname": "b"], key: "cookie")
        let content = try await AuthBackupManager(store: YunXBackupStore(vault: source)).export(password: "backup-pass")
        XCTAssertFalse(content.contains("secret-value"))
        let target = vault()
        _ = try await AuthBackupManager(store: YunXBackupStore(vault: target)).import(content, password: "backup-pass")
        XCTAssertEqual(try target.accounts().map(\.nickname).sorted(), ["b", "one", "two"])
    }

    func testPrintingAnAccountShowsNoSecret() {
        let account = YunXAccount(id: "1", platform: "quark", fields: ["cookie": "secret-value"], updatedAt: 0, isPrimary: true)
        XCTAssertFalse("\(account)".contains("secret-value"))
        XCTAssertFalse(String(reflecting: account).contains("secret-value"))
        XCTAssertFalse(String(describing: Mirror(reflecting: account).children.map(\.value)).contains("secret-value"))
    }

    func testVideoFileNamesFallBackToTheTitle() {
        XCTAssertEqual(YunXDownloadModel.fileName(VideoMedia(url: "u", kind: .video), title: "clip"), "clip.mp4")
        XCTAssertEqual(YunXDownloadModel.fileName(VideoMedia(url: "u", kind: .image, fileName: "a.png"), title: "clip"), "a.png")
    }
}

// MARK: Model wiring

private final class FakeDrive: CloudDriveProvider, @unchecked Sendable {
    let platform = DrivePlatform.quark
    let capabilities: DriveCapabilities = [.shareListing, .guestShareAccess, .ownFiles, .saveToDrive]
    var credentialRefreshInterval: TimeInterval? = 100
    var tree: [String: [DriveFile]] = [:]
    var host = "dl.example"
    var nickname = "named"
    private let lock = NSLock()
    private(set) var saved: [(String, String?)] = []
    private(set) var resolves = 0
    private(set) var resolveCredentials: [String?] = []
    private(set) var openedPasscodes: [String?] = []
    private(set) var refreshes: [String] = []
    var refreshWorks = true

    func isWellFormed(credential: DriveCredential) -> Bool { true }
    func accountState(credential: DriveCredential?) async -> DriveAccountState { .signedIn(nickname: nickname) }
    func refreshCredential(_ credential: DriveCredential) async -> DriveCredential? {
        lock.withLock { refreshes.append(credential.value) }
        return refreshWorks ? DriveCredential(credential.value + "+") : nil
    }
    func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession {
        lock.withLock { openedPasscodes.append(passcode) }
        return ShareSession(platform: platform, shareId: link.shareId, accessToken: "stoken", title: "share")
    }
    func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] {
        tree[directoryId ?? ""] ?? []
    }
    func listFiles(directoryId: String?, credential: DriveCredential) async throws -> [DriveFile] { tree[directoryId ?? ""] ?? [] }
    func saveToDrive(session: ShareSession, file: DriveFile, directoryId: String?, credential: DriveCredential, skipSpaceCheck: Bool) async throws -> String {
        lock.withLock { saved.append((file.id, directoryId)) }
        return "new"
    }
    func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink {
        lock.withLock { resolves += 1; resolveCredentials.append(credential?.value) }
        return ResolvedLink(url: URL(string: "https://\(host)/\(file.id)?sign=SECRETSIGN")!, headers: ["Cookie": "SECRETCOOKIE"], fileId: file.id, filename: file.name, size: 4)
    }
}

/// Serves four bytes at once, or holds every request open until told to go.
private final class BytesTransport: DownloadTransport, @unchecked Sendable {
    func fetch(_ request: FetchRequest) async throws -> FetchResponse {
        let body = AsyncThrowingStream<Data, Error> { continuation in
            continuation.yield(Data("data".utf8))
            continuation.finish()
        }
        return FetchResponse(info: HTTPResponseInfo(statusCode: 200, headers: ["content-length": "4"]), body: body)
    }
}

/// Gopeed's REST API, enough for a task that is already finished.
private final class GopeedAPI: MediaHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private var _failContinue = false
    private var _savePath = ""
    var failContinue: Bool { get { lock.withLock { _failContinue } } set { lock.withLock { _failContinue = newValue } } }
    var savePath: String { get { lock.withLock { _savePath } } set { lock.withLock { _savePath = newValue } } }

    func called(_ method: String, _ path: String) -> Bool { lock.withLock { seen.contains("\(method) \(path)") } }

    func send(_ request: MediaRequest) async throws -> MediaResponse {
        lock.withLock { seen.append("\(request.method) \(request.url.path)") }
        var object: [String: Any] = ["code": 0, "data": [String: Any]()]
        if request.url.path == "/api/v1/tasks" { object["data"] = [Any]() }
        if request.url.path == "/api/v1/tasks/old", request.method == "GET" {
            object["data"] = ["status": "done", "meta": ["opts": ["path": savePath], "res": ["files": [["name": "movie.bin", "path": ""]]]]]
        }
        if request.url.path.hasSuffix("/continue"), failContinue { object = ["code": 500, "msg": "no"] }
        let body = try JSONSerialization.data(withJSONObject: object)
        let stream = AsyncThrowingStream<Data, Error> { $0.yield(body); $0.finish() }
        return MediaResponse(statusCode: 200, finalURL: request.url, body: stream)
    }
}

private final class GopeedStubProcess: GopeedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var running = true
    let pid: Int32 = 4242
    var isRunning: Bool { lock.withLock { running } }
    var exitCode: Int32? { nil }
    func terminate() { lock.withLock { running = false } }
    func forceKill() { terminate() }
}

private struct GopeedStubLauncher: GopeedLauncher {
    func launch(executable: URL, arguments: [String], environment: [String: String], workingDirectory: URL) throws -> GopeedProcess { GopeedStubProcess() }
    func executablePath(pid: Int32) -> String? { nil }
    func forceKill(pid: Int32) {}
    func freePort() throws -> Int { 53111 }
}

private func file(_ id: String, dir: Bool = false, name: String? = nil) -> DriveFile {
    DriveFile(id: id, name: name ?? id, size: 4, isDirectory: dir, parentId: "")
}

@MainActor
final class YunXModelTests: XCTestCase {
    private var temp: URL!
    private let shareURL = "https://pan.quark.cn/s/abc123"

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: temp) }

    private func model(_ drive: FakeDrive, jobs: MemoryBackend = MemoryBackend(), vault: YunXVault? = nil,
                       defaults: UserDefaults? = nil, trackers: MemoryBackend = MemoryBackend(), gopeed: GopeedEngine? = nil) -> YunXDownloadModel {
        let store = DownloadStore(root: temp.appendingPathComponent("store"))
        let suite = defaults ?? UserDefaults(suiteName: UUID().uuidString)!
        let made = YunXDownloadModel(
            vault: vault ?? YunXVault(backend: MemoryBackend(), now: { 1 }), settingsStore: YunXSettingsStore(defaults: suite, trackers: trackers),
            jobStore: YunXJobStore(backend: jobs), drives: CloudDriveRegistry(providers: [drive]), downloadStore: store,
            toolsRoot: { [temp] in MediaToolsRoot(url: temp!.appendingPathComponent("tools")) }, gopeed: gopeed,
            makeEngine: { DownloadEngine(configuration: $0, transport: BytesTransport(), store: store) })
        made.settings.saveDirectory = temp.appendingPathComponent("out").path
        return made
    }

    private func settled(_ model: YunXDownloadModel, count: Int, _ line: UInt = #line) async {
        for _ in 0..<500 {
            if model.jobs.count == count, model.jobs.allSatisfy({ !$0.state.isActive }), !model.busy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("jobs did not settle: \(model.jobs.map(\.state))", line: line)
    }

    /// Opened as a guest, then signed in: the download must use the account, as the page shows it.
    func testAccountAddedAfterOpeningAShareIsUsedForTheDownload() async throws {
        let drive = FakeDrive()
        drive.credentialRefreshInterval = nil
        drive.tree[""] = [DriveFile(id: "f", name: "big.bin", size: 4, isDirectory: false, parentId: "")]
        let made = model(drive)
        made.link = "https://pan.quark.cn/s/abc123"
        await made.open()
        XCTAssertEqual(made.files.count, 1)
        XCTAssertFalse(made.canSaveToDrive)
        try made.vault.add(platform: "quark", fields: ["cookie": "signed-in"], key: "cookie")
        made.reloadAccounts()
        XCTAssertTrue(made.canSaveToDrive)
        made.downloadSelected(only: made.files[0])
        await settled(made, count: 1)
        XCTAssertEqual(drive.resolveCredentials, ["signed-in"])
    }

    func testFolderDownloadRecursesKeepsPathsGroupsAndClearsRecords() async throws {
        let drive = FakeDrive()
        drive.tree = ["": [file("Folder", dir: true), file("top.bin")],
                      "Folder": [file("a.bin"), file("Sub", dir: true), file("Folder", dir: true)],
                      "Sub": [file("b.bin")]]
        let jobs = MemoryBackend()
        let model = model(drive, jobs: jobs)
        model.link = shareURL
        await model.open()
        XCTAssertNil(model.error)
        model.selected = ["Folder", "top.bin"]
        model.downloadSelected()
        await settled(model, count: 3)
        XCTAssertEqual(Set(model.jobs.map(\.relativeName)), ["top.bin", "Folder/a.bin", "Folder/Sub/b.bin"])
        let out = temp.appendingPathComponent("out")
        XCTAssertEqual(try String(contentsOf: out.appendingPathComponent("Folder/Sub/b.bin"), encoding: .utf8), "data")
        XCTAssertEqual(model.jobGroups.filter(\.isFolder).map(\.title), ["Folder"])
        XCTAssertEqual(model.jobGroups.first(where: \.isFolder)?.jobs.count, 2)
        XCTAssertEqual(model.jobGroups.count, 2)
        XCTAssertEqual(YunXJobStore(backend: jobs).load(), [])
    }

    func testWalkerStopsAtTheFileCap() async {
        let many = (0...YunXFolderWalker.maxFiles).map { file("f\($0)") }
        do {
            _ = try await YunXFolderWalker.walk(file("root", dir: true)) { _ in many }
            XCTFail("expected a refusal")
        } catch { XCTAssertEqual(error as? YunXLoginError, .folderTooLarge) }
    }

    func testRestoreListsPausedThenReopensShareOnResumeWithNoLinkOnDisk() async throws {
        let drive = FakeDrive()
        drive.tree = ["": [file("a.bin")]]
        let jobs = MemoryBackend()
        let record = YunXJobRecord(id: UUID(), kind: .share, name: "Folder/a.bin", saveDirectory: temp.appendingPathComponent("out").path,
                                   platform: "quark", shareId: "abc123", passcode: "pw12", fileId: "a.bin", fileName: "a.bin", fileSize: 4)
        YunXJobStore(backend: jobs).put(record)
        let model = model(drive, jobs: jobs)
        model.restoreJobs()
        model.restoreJobs()
        XCTAssertEqual(model.jobs.map(\.state), [.notStarted])
        XCTAssertEqual(drive.resolves, 0, "listing must not touch the network")
        model.resume(model.jobs[0])
        await settled(model, count: 1)
        guard case .finished? = model.jobs.first?.state else { return XCTFail("\(model.jobs)") }
        XCTAssertEqual(drive.openedPasscodes, ["pw12"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.appendingPathComponent("out/Folder/a.bin").path))
    }

    func testRestoreKeepsTheFailureReasonAndRetryClearsIt() async throws {
        let drive = FakeDrive()
        drive.tree = ["": [file("a.bin")]]
        let jobs = MemoryBackend()
        var record = YunXJobRecord(id: UUID(), kind: .share, name: "a.bin", saveDirectory: temp.appendingPathComponent("out").path,
                                   platform: "quark", shareId: "abc123", fileId: "a.bin", fileName: "a.bin", fileSize: 4)
        record.failure = "链接已失效"
        YunXJobStore(backend: jobs).put(record)
        let model = model(drive, jobs: jobs)
        model.restoreJobs()
        XCTAssertEqual(model.jobs.map(\.state), [.failed("链接已失效")])
        XCTAssertTrue(model.jobs[0].canRetry)
        model.resume(model.jobs[0])
        await settled(model, count: 1)
        guard case .finished? = model.jobs.first?.state else { return XCTFail("\(model.jobs)") }
    }

    func testNoSignedLinkOrCookieReachesTheRecordsOrStateFiles() async throws {
        let drive = FakeDrive()
        drive.tree = ["": [file("a.bin")]]
        let jobs = RecordingBackend()
        let model = model(drive, jobs: jobs)
        model.link = shareURL
        await model.open()
        model.downloadSelected(only: drive.tree[""]![0])
        await settled(model, count: 1)
        let written = jobs.writes.map { String(decoding: $0, as: UTF8.self) }.joined()
        XCTAssertFalse(written.isEmpty)
        XCTAssertFalse(written.contains("SECRET"))
    }

    func testSpeedLimitAndSettingsPersistWithoutTrackersInDefaults() throws {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let trackers = MemoryBackend()
        let drive = FakeDrive()
        let first = model(drive, defaults: defaults, trackers: trackers)
        first.settings.speedLimitKB = 8
        first.settings.proxyMode = .manual
        first.settings.proxyHost = "user:pw@host"
        first.settings.trackers = ["https://t.example/PASSKEY/announce", " "]
        let plist = try XCTUnwrap(defaults.data(forKey: "yunx.download.settings"))
        let text = String(decoding: plist, as: UTF8.self)
        XCTAssertFalse(text.contains("PASSKEY"))
        XCTAssertFalse(text.contains("user:pw"))
        XCTAssertEqual(first.settings.speedLimitBytes, 8192)
        XCTAssertEqual(first.settings.gopeed.trackers, ["https://t.example/PASSKEY/announce"])
        let second = model(drive, defaults: defaults, trackers: trackers)
        XCTAssertEqual(second.settings.trackers.first, "https://t.example/PASSKEY/announce")
        XCTAssertEqual(second.settings.proxyHost, "")
    }

    func testSaveToDriveUsesTheFolderPicked() async throws {
        let drive = FakeDrive()
        drive.tree = ["": [file("a.bin"), file("mine", dir: true)]]
        let vault = YunXVault(backend: MemoryBackend(), now: { Int64(Date().timeIntervalSince1970 * 1000) })
        try vault.add(platform: "quark", fields: ["cookie": "c"], key: "cookie")
        let model = model(drive, vault: vault)
        model.link = shareURL
        await model.open()
        XCTAssertTrue(model.canSaveToDrive)
        model.selected = ["a.bin"]
        await model.beginSave()
        XCTAssertEqual(model.savePicker?.folders.map(\.id), ["mine"])
        await model.pickerEnter(file("mine", dir: true))
        await model.confirmSave()
        XCTAssertEqual(drive.saved.first?.0, "a.bin")
        XCTAssertEqual(drive.saved.first?.1, "mine")
        XCTAssertNotNil(model.notice)
        XCTAssertNil(model.savePicker)
    }

    func testGuestShareCannotSaveToDrive() async {
        let drive = FakeDrive()
        drive.tree = ["": [file("a.bin")]]
        let model = model(drive)
        model.link = shareURL
        await model.open()
        XCTAssertFalse(model.canSaveToDrive)
    }

    func testRefreshRotatesDueAccountsBacksOffAndBackfillsNames() async throws {
        let drive = FakeDrive()
        let vault = YunXVault(backend: MemoryBackend(), now: { 1000 })
        try vault.add(platform: "quark", fields: ["cookie": "old", "nickname": ""], key: "cookie")
        let model = model(drive, vault: vault)
        let due = Date(timeIntervalSince1970: 1000)
        await model.refreshAccounts(now: Date(timeIntervalSince1970: 50))
        XCTAssertEqual(drive.refreshes, [], "not due yet")
        XCTAssertEqual(try vault.active("quark")?.nickname, "named")
        await model.refreshAccounts(now: due)
        XCTAssertEqual(try vault.active("quark")?.fields["cookie"], "old+")

        drive.refreshWorks = false
        let later = due.addingTimeInterval(10_000)
        await model.refreshAccounts(now: later)
        let tries = drive.refreshes.count
        await model.refreshAccounts(now: later.addingTimeInterval(1))
        XCTAssertEqual(drive.refreshes.count, tries, "a failed drive waits")
        await model.refreshAccounts(now: later.addingTimeInterval(YunXDownloadModel.refreshRetry + 1))
        XCTAssertEqual(drive.refreshes.count, tries + 1)
    }

    func testPastedBareXunleiTokenIsMarkedAsWeb() async throws {
        let parsed = XunleiCredential.parseWebLogin("Bearer abcdefghijklmnop.qrstuvwx")
        XCTAssertEqual(parsed?.authType, XunleiWebAuth.authType)
        let fake = FakeDrive()
        let model = model(fake)
        do {
            try await model.saveLogin(.drive(.xunlei), secret: "x")
            XCTFail("no xunlei provider here")
        } catch { XCTAssertEqual(error as? DriveError, .providerUnavailable(.xunlei)) }
    }

    func testSeparateTracksAskForFfmpegFirstAndDeclineUsesBuiltIn() async throws {
        let model = model(FakeDrive())
        let media = VideoMedia(url: "https://v.example/a.m4s", kind: .video, audioUrl: "https://v.example/b.m4s")
        model.loadVideoForTesting(VideoParseResult(platform: .bilibili, title: "clip", medias: [media]))
        model.download(media)
        XCTAssertEqual(model.pendingFfmpeg?.url, media.url)
        XCTAssertTrue(model.jobs.isEmpty)
        model.declineFfmpeg()
        XCTAssertNil(model.pendingFfmpeg)
        XCTAssertEqual(model.jobs.count, 1)
        model.cancel(model.jobs[0])
    }

    private func engine(_ api: GopeedAPI) throws -> GopeedEngine {
        let root = MediaToolsRoot(url: temp.appendingPathComponent("tools"))
        let binary = root.gopeedExecutable
        try FileManager.default.createDirectory(at: binary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xCF, 0xFA, 0xED, 0xFE, 1, 2, 3]).write(to: binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
        return GopeedEngine(root: root, transport: api, launcher: GopeedStubLauncher(), runner: ProcessToolRunner(), readyTimeout: 2, stopTimeout: 0.1)
    }

    private func waitFor(_ line: UInt = #line, _ done: () async -> Bool) async {
        for _ in 0..<500 {
            if await done() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("timed out", line: line)
    }

    private func restoredP2P(_ jobs: MemoryBackend, task: String) {
        YunXJobStore(backend: jobs).put(YunXJobRecord(id: UUID(), kind: .p2p, name: "t", saveDirectory: temp.path,
                                                      p2pURL: "magnet:?xt=urn:btih:0", gopeedTask: task))
    }

    func testCancellingARestoredP2PJobDeletesItsGopeedTaskAndStopsTheKernel() async throws {
        let api = GopeedAPI()
        let gopeed = try engine(api)
        let jobs = MemoryBackend()
        restoredP2P(jobs, task: "old")
        let model = model(FakeDrive(), jobs: jobs, gopeed: gopeed)
        model.restoreJobs()
        model.cancel(try XCTUnwrap(model.jobs.first))
        await waitFor { api.called("DELETE", "/api/v1/tasks/old") }
        await waitFor { await gopeed.state != .running }
    }

    func testAFailedContinueRetiresTheTaskAndQuarantineCoversFinishedFiles() async throws {
        let api = GopeedAPI()
        api.failContinue = true
        let gopeed = try engine(api)
        let jobs = MemoryBackend()
        restoredP2P(jobs, task: "old")
        let model = model(FakeDrive(), jobs: jobs, gopeed: gopeed)
        model.restoreJobs()
        model.resume(try XCTUnwrap(model.jobs.first))
        await waitFor { api.called("DELETE", "/api/v1/tasks/old") }
        await settled(model, count: 1)
        guard case .failed = model.jobs[0].state else { return XCTFail("\(model.jobs[0].state)") }
        XCTAssertEqual(YunXJobStore(backend: jobs).load().first?.gopeedTask, "")

        let output = temp.appendingPathComponent("movie.bin")
        try Data("x".utf8).write(to: output)
        api.failContinue = false
        api.savePath = temp.path
        let again = self.model(FakeDrive(), jobs: { let fresh = MemoryBackend(); self.restoredP2P(fresh, task: "old"); return fresh }(), gopeed: gopeed)
        again.restoreJobs()
        again.resume(try XCTUnwrap(again.jobs.first))
        await settled(again, count: 1)
        let values = try output.resourceValues(forKeys: [.quarantinePropertiesKey])
        XCTAssertNotNil(values.quarantineProperties)
    }

    func testCancellingTheTorrentPickerStopsAnIdleKernel() async throws {
        let api = GopeedAPI()
        let gopeed = try engine(api)
        try await gopeed.start()
        let model = model(FakeDrive(), gopeed: gopeed)
        model.torrentPick = YunXTorrentPick(url: "magnet:?xt=urn:btih:0", name: "t", files: [], selected: [])
        model.cancelTorrent()
        XCTAssertNil(model.torrentPick)
        await waitFor { await gopeed.state != .running }
    }

    func testPreviewOffersOnlyWhatAVPlayerCanPlayWithSound() {
        let model = model(FakeDrive())
        XCTAssertTrue(model.previewable(file("a.mp4")))
        XCTAssertFalse(model.previewable(file("a.mkv")))
        XCTAssertFalse(model.previewable(VideoMedia(url: "u", kind: .video, audioUrl: "a")))
        XCTAssertEqual(MediaPreview.kind(of: URL(string: "https://x.example/get?id=1")!, fileName: "a.mp4"), .mp4)
    }

    func testTorrentSelectionSendsNothingWhenEverythingIsTicked() {
        let files = [GopeedResolvedFile(name: "a", path: "", size: 1), GopeedResolvedFile(name: "b", path: "d", size: 1)]
        var pick = YunXTorrentPick(url: "magnet:", name: "n", files: files, selected: [0, 1])
        XCTAssertEqual(pick.selection, [])
        pick.selected = [1]
        XCTAssertEqual(pick.selection, [1])
        XCTAssertEqual(files[1].displayPath, "d/b")
    }

    func testRecordsPrintNoPasscode() {
        let record = YunXJobRecord(id: UUID(), kind: .share, name: "a", saveDirectory: "/", passcode: "SECRET")
        XCTAssertFalse("\(record)".contains("SECRET"))
        XCTAssertFalse(String(reflecting: record).contains("SECRET"))
    }
}

private final class RecordingBackend: MemoryBackend, @unchecked Sendable {
    var writes: [Data] = []
    override func write(_ data: Data) throws { writes.append(data); try super.write(data) }
}

/// Answers each Xunlei login endpoint by the shape of its URL.
private final class XunleiFlow: HTTPTransport, @unchecked Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        let text = String(decoding: request.body ?? Data(), as: UTF8.self)
        let json: String
        if url.contains("token") {
            json = #"{"access_token":"access-token-value-1","refresh_token":"refresh-token-value-1"}"#
        } else if url.contains("captcha") {
            json = #"{"captcha_token":"captcha"}"#
        } else if text.contains("smsCode") {
            json = #"{"errorCode":"0","sessionID":"session","userID":"7","nickName":"n"}"#
        } else if text.contains("mobile") {
            json = #"{"errorCode":"0","creditkey":"ck","token":"tk"}"#
        } else {
            json = #"{"errorCode":"1007","review_panel":"x","reviewurl":"https://r.example/?creditkey=ck"}"#
        }
        return HTTPResponse(statusCode: 200, body: Data(json.utf8))
    }
}

private final class ArgsLog: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [[String]] = []
    func add(_ args: [String]) { lock.withLock { calls.append(args) } }
    var all: [[String]] { lock.withLock { calls } }
}

private final class VerifyingDrive: CloudDriveProvider, @unchecked Sendable {
    let platform = DrivePlatform.quark
    let capabilities: DriveCapabilities = []
    var credentialRefreshInterval: TimeInterval? = nil
    let state: DriveAccountState
    init(_ state: DriveAccountState) { self.state = state }
    func isWellFormed(credential: DriveCredential) -> Bool { true }
    func accountState(credential: DriveCredential?) async -> DriveAccountState { state }
    func refreshCredential(_ credential: DriveCredential) async -> DriveCredential? { nil }
    func openShare(_ link: ParsedShareLink, passcode: String?, credential: DriveCredential?) async throws -> ShareSession { throw DriveError.loginRequired }
    func listShareFiles(session: ShareSession, directoryId: String?, credential: DriveCredential?) async throws -> [DriveFile] { [] }
    func resolveShareFile(session: ShareSession, file: DriveFile, credential: DriveCredential?, options: ShareResolveOptions) async throws -> ResolvedLink { throw DriveError.loginRequired }
}

@MainActor
final class YunXChromeLoginTests: XCTestCase {
    private static let browsers = #"{"data":{"browsers":[{"dir":"Profile 3","connected":false,"default":false},{"dir":"Default","connected":true,"default":true}]},"success":true}"#
    private static let loggedIn = #"{"success":true,"data":[{"name":"__pus","value":"a","domain":".quark.cn"},{"name":"__puus","value":"b","domain":"pan.quark.cn","expires":4102444800},{"name":"other","value":"x","domain":".notquark.cn"}]}"#
    private static let loggedOut = #"{"success":true,"data":[{"name":"__pus","value":"a","domain":".quark.cn"},{"name":"__puus","value":"old","domain":".quark.cn","expires":1000}]}"#

    private func fake(_ export: String?, log: ArgsLog = ArgsLog()) -> YunXChromeCookies {
        YunXChromeCookies {
            { args in
                log.add(args)
                return args[0] == "browsers" ? Self.browsers : export
            }
        }
    }

    private func run(_ chrome: YunXChromeCookies, state: DriveAccountState = .signedIn(nickname: "me")) async throws -> YunXDownloadModel {
        let settings = YunXSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, trackers: ChromeMemoryBackend())
        let model = YunXDownloadModel(vault: YunXVault(backend: ChromeMemoryBackend()), settingsStore: settings,
                                      jobStore: YunXJobStore(backend: ChromeMemoryBackend()),
                                      drives: CloudDriveRegistry(providers: [VerifyingDrive(state)]), chromeCookies: chrome)
        await model.addAccount(.drive(.quark))
        return model
    }

    func testImportsReadOnlyFromTheConnectedProfileWithoutTheSheet() async throws {
        let log = ArgsLog()
        let model = try await run(fake(Self.loggedIn, log: log))
        XCTAssertNil(model.login)
        XCTAssertNotNil(model.notice)
        XCTAssertEqual(try model.vault.active("quark")?.fields[YunXBackupStore.key("quark")], "__pus=a; __puus=b")
        XCTAssertEqual(log.all, [["browsers", "--json"], ["cookies", "export", "--from", "Default", "--domain", "quark.cn", "--json"]])
    }

    private func make(_ chrome: YunXChromeCookies, state: DriveAccountState = .signedIn(nickname: "me")) -> YunXDownloadModel {
        let settings = YunXSettingsStore(defaults: UserDefaults(suiteName: UUID().uuidString)!, trackers: ChromeMemoryBackend())
        let model = YunXDownloadModel(vault: YunXVault(backend: ChromeMemoryBackend()), settingsStore: settings,
                                      jobStore: YunXJobStore(backend: ChromeMemoryBackend()),
                                      drives: CloudDriveRegistry(providers: [VerifyingDrive(state)]), chromeCookies: chrome)
        model.chromePollInterval = .milliseconds(5)
        model.chromePollTimeout = .milliseconds(60)
        return model
    }

    func testMissingChromeUseAsksForItAndNeverOpensASheet() async throws {
        let model = make(YunXChromeCookies(runner: { nil }))
        await model.addAccount(.drive(.quark))
        XCTAssertNil(model.login)
        XCTAssertEqual(model.error, tr("Install chrome-use to sign in."))
    }

    func testNotLoggedInOpensChromeAndTimesOutWithoutASheet() async throws {
        let log = ArgsLog()
        let model = make(fake(Self.loggedOut, log: log))
        await model.addAccount(.drive(.quark))
        XCTAssertNil(model.login)
        XCTAssertNil(model.chromeWaiting)
        XCTAssertNotNil(model.error)
        XCTAssertTrue(log.all.contains(["--session", "thermo-yunx", "open", QuarkConstants.loginURL, "--new-tab"]))
        XCTAssertTrue(log.all.contains(["--session", "thermo-yunx", "cookies", "get", "--json"]))
        XCTAssertTrue(model.accounts.isEmpty)
    }

    func testLoginAppearingInTheLiveBrowserIsSaved() async throws {
        let live = #"{"success":true,"data":{"cookies":[{"name":"__pus","value":"a","domain":".quark.cn","expires":-1},{"name":"__puus","value":"b","domain":".quark.cn","expires":-1}]}}"#
        let model = make(YunXChromeCookies(runner: {
            { args in
                if args.contains("browsers") { return Self.browsers }
                if args.contains("get") { return live }
                return args.contains("open") ? "" : Self.loggedOut
            }
        }))
        model.chromePollTimeout = .seconds(5)
        await model.addAccount(.drive(.quark))
        XCTAssertEqual(try model.vault.active("quark")?.fields["cookie"], "__pus=a; __puus=b")
        XCTAssertNotNil(model.notice)
    }

    func testCancelStopsWatching() async throws {
        let log = ArgsLog()
        let model = make(fake(Self.loggedOut, log: log))
        model.chromePollTimeout = .seconds(30)
        let add = Task { await model.addAccount(.drive(.quark)) }
        while model.chromeWaiting == nil { try await Task.sleep(for: .milliseconds(2)) }
        model.cancelChromeLogin()
        await add.value
        let count = log.all.count
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(log.all.count, count)
        XCTAssertNil(model.chromeWaiting)
        XCTAssertNil(model.error)
    }

    func testChromeThatCannotOpenSaysSo() async throws {
        var chrome = YunXChromeCookies(runner: { { args in args[0] == "browsers" ? Self.browsers : nil } })
        chrome.openInChrome = { _ in false }
        let model = make(chrome)
        await model.addAccount(.drive(.quark))
        XCTAssertEqual(model.error, tr("Could not open Chrome. Install Google Chrome, then try again."))
    }

    func testUnverifiedLoginIsNotSaved() async throws {
        for state in [DriveAccountState.signedOut, .unverified] {
            let model = make(fake(Self.loggedIn), state: state)
            await model.addAccount(.drive(.quark))
            XCTAssertNil(model.login)
            XCTAssertTrue(model.accounts.isEmpty)
            XCTAssertNil(model.notice)
        }
    }

    func testXunleiReadsLocalStorageFromItsChromeTabAndFormsStayLocal() async throws {
        let log = ArgsLog()
        let model = make(fake(Self.loggedIn, log: log))
        await model.addAccount(.drive(.xunlei))
        XCTAssertTrue(log.all.contains { $0.contains("eval") })
        XCTAssertFalse(log.all.contains { $0.contains("export") })
        XCTAssertNil(model.login)
        let before = log.all.count
        await model.addAccount(.drive(.pan123))
        XCTAssertEqual(log.all.count, before)
        XCTAssertEqual(model.login, .drive(.pan123))
    }

    func testHostsMatchExactly() {
        XCTAssertTrue(YunXChromeCookies.belongs(".115.com", to: ["115.com"]))
        XCTAssertTrue(YunXChromeCookies.belongs("my.115.com", to: ["115.com"]))
        XCTAssertFalse(YunXChromeCookies.belongs("x115.com", to: ["115.com"]))
    }
}

private final class SetupRuns: @unchecked Sendable {
    let lock = NSLock()
    var calls: [(String, [String], [String: String])] = []
    var probes: [YunXChromeUseSetup.Probe]
    var failing: String?
    init(_ probes: [YunXChromeUseSetup.Probe]) { self.probes = probes }
    func next() -> YunXChromeUseSetup.Probe { lock.withLock { probes.count > 1 ? probes.removeFirst() : probes[0] } }
    func run(_ tool: String, _ args: [String], _ env: [String: String]) -> Int32 {
        lock.withLock { calls.append((tool, args, env)); return tool == failing ? 7 : 0 }
    }
}

@MainActor
final class YunXChromeUseSetupTests: XCTestCase {
    private func make(_ runs: SetupRuns) -> YunXChromeUseSetup {
        YunXChromeUseSetup(detect: { runs.next() }, run: { tool, args, env, line in
            line("ran \(tool)")
            return runs.run(tool, args, env)
        }, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    func testDetected() async {
        let runs = SetupRuns([.init(tool: "/x/chrome-use", connected: true)])
        let setup = make(runs)
        await setup.refresh()
        XCTAssertEqual(setup.state, .ready)
        XCTAssertTrue(runs.calls.isEmpty)
    }

    func testMissingRunsNothingUntilTheClickThenInstalls() async {
        let runs = SetupRuns([.init(), .init(tool: "/x/chrome-use", connected: false, profile: "Leo")])
        let setup = make(runs)
        await setup.refresh()
        XCTAssertEqual(setup.state, .missing)
        XCTAssertTrue(runs.calls.isEmpty)
        await setup.install()
        XCTAssertEqual(runs.calls.map(\.0), ["/usr/bin/curl", "/bin/sh", "/x/chrome-use"])
        XCTAssertEqual(runs.calls[0].1.last, YunXChromeUseSetup.installerURL)
        XCTAssertEqual(runs.calls[2].1, ["extension", "install", "--no-open"])
        XCTAssertEqual(setup.state, .notConnected)
        XCTAssertFalse(setup.output.isEmpty)
        XCTAssertNil(setup.failure)
    }

    func testInstallFailureStopsAndShows() async {
        let runs = SetupRuns([.init()])
        runs.failing = "/usr/bin/curl"
        let setup = make(runs)
        await setup.refresh()
        await setup.install()
        XCTAssertEqual(runs.calls.count, 1)
        XCTAssertNotNil(setup.failure)
        XCTAssertEqual(setup.state, .missing)
        XCTAssertFalse(setup.working)
    }

    func testConnectAsksChromeUseThenChecksAgain() async {
        let runs = SetupRuns([.init(tool: "/x/chrome-use", connected: false, profile: "Leo"), .init(tool: "/x/chrome-use", connected: true)])
        let setup = make(runs)
        await setup.refresh()
        await setup.connect()
        XCTAssertEqual(runs.calls.last?.1, ["connect", "--browser", "Leo", "--wait", "120"])
        XCTAssertEqual(setup.state, .ready)
    }
}

private final class ChromeMemoryBackend: YunXSecretBackend, @unchecked Sendable {
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}
