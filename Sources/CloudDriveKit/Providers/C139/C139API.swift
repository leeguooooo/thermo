// Ported from YunX-Desktop (AGPL-3.0): data/network/C139Api.kt.
// Endpoints, parameters, signing and error handling follow that file. Lookups that returned null there and
// swallow their errors return nil here; the others throw `DriveError`.
//
// Three request shapes, as there:
//  - share listing and title: anonymous, body encrypted, no Authorization and no mcloud-sign;
//  - share link and transfer: body encrypted, mcloud-sign computed over the plain body, Authorization if known;
//  - personal drive: plain JSON, Authorization and mcloud-sign, plus the Cookie for share creation and quota.
import Foundation

public struct C139ShareInfo: Sendable, Equatable {
    public let shareURL: String
    public let passcode: String
    public let linkId: String
    public let title: String
    /// 1 forever, 2 one day, 3 seven days, 4 thirty days, 0 unknown. The response carries no expiry, so this echoes the request.
    public let expiredType: Int
}

public struct C139DownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let fid: String
    public let filename: String
    public let downloadURL: String
    public let size: Int64
    public var description: String { "C139DownloadLink(\(fid), \(filename), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid, "filename": filename, "size": size]) }
}

public struct C139TaskStatus: Sendable, Equatable {
    public let status: String
    public let progress: Int
    /// `(fileId, errCode)` per file.
    public let results: [(fileId: String, errorCode: String)]

    public static func == (lhs: C139TaskStatus, rhs: C139TaskStatus) -> Bool {
        lhs.status == rhs.status && lhs.progress == rhs.progress
            && lhs.results.map { [$0.fileId, $0.errorCode] } == rhs.results.map { [$0.fileId, $0.errorCode] }
    }
}

public struct C139TransferResult: Sendable, Equatable {
    public let done: Bool
    /// Source coID to the new file id.
    public let mapping: [String: String]
}

public struct C139FilePage: Sendable, Equatable {
    public let files: [DriveFile]
    public let nextCursor: String?
}

/// Clock and randomness behind the signature and the encryption IV, replaceable so tests can pin them.
public struct C139Environment: Sendable {
    public var now: @Sendable () -> Date
    /// 16 letters or digits.
    public var nonce: @Sendable () -> String
    /// 16 bytes.
    public var iv: @Sendable () -> [UInt8]

    public init(now: @escaping @Sendable () -> Date = { Date() },
                nonce: @escaping @Sendable () -> String = C139Environment.randomNonce,
                iv: @escaping @Sendable () -> [UInt8] = { (0..<16).map { _ in UInt8.random(in: .min ... .max) } }) {
        self.now = now
        self.nonce = nonce
        self.iv = iv
    }

    public static let randomNonce: @Sendable () -> String = {
        let pool = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return String((0..<16).map { _ in pool.randomElement()! })
    }
}

public actor C139API {
    private let transport: any HTTPTransport
    private let environment: C139Environment

    public init(transport: any HTTPTransport = URLSessionTransport(), environment: C139Environment = C139Environment()) {
        self.transport = transport
        self.environment = environment
    }

    private static let missingAuthorization = "登录态缺少 authorization，请重新登录"

    // MARK: Signing

    /// `<ts>,<rand>,<sign>`, with ts as `yyyy-MM-dd HH:mm:ss` in the local time zone.
    func signHeader(_ bodyJSON: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let timestamp = formatter.string(from: environment.now())
        let nonce = environment.nonce()
        return "\(timestamp),\(nonce),\(C139Crypto.calSign(bodyJSON: bodyJSON, timestamp: timestamp, nonce: nonce))"
    }

    // MARK: Shares

    /// getOutLinkGeneral, anonymous. The title and the passcode 139 echoes in clear (the web page fills it in too);
    /// either is nil when the call fails or the field is blank. Transport errors still throw.
    public func getOutLinkGeneral(linkId: String) async throws -> (title: String?, passcode: String?) {
        let plain = try Self.jsonString(["getOutLinkGeneralReq": ["linkID": linkId, "isPasswd": 1, "account": ""] as [String: Any]])
        let json = try await sharePost(C139Constants.shareGeneralURL, plain: plain, authorization: nil, signed: false)
        let code = json.string("resultCode")
        if !code.isBlankText, code != "0" { return (nil, nil) }
        if !Self.successFlag(json) { return (nil, nil) }
        guard let first = json.child("data")?.child("getOutLinkGeneralResp")?.objects("outLinkGeneral").first else { return (nil, nil) }
        return (first.string("lkName").nonBlank, first.string("passwd").nonBlank)
    }

    public func getOutLinkTitle(linkId: String) async throws -> String? { try await getOutLinkGeneral(linkId: linkId).title }
    public func getOutLinkPassword(linkId: String) async throws -> String? { try await getOutLinkGeneral(linkId: linkId).passcode }

    /// getOutLinkInfoV6, anonymous. 139 puts sub-folders in `caLst` and files in `coLst` (a `coType` of 2 is a folder
    /// too); both are returned, folders first. A wrong passcode answers 9188, an incomplete body 9530.
    /// - Parameter parentId: "root" for the top, else the parent caID or folder coID.
    public func getShareFiles(linkId: String, parentId: String, passcode: String, begin: Int = 1, end: Int = 200) async throws -> [DriveFile] {
        let request: [String: Any] = [
            "account": "", "linkID": linkId, "passwd": passcode,
            "caSrt": 1, "coSrt": 1, "srtDr": 0, "bNum": begin, "pCaID": parentId, "eNum": end,
        ]
        let plain = try Self.jsonString(["getOutLinkInfoReq": request])
        let json = try await sharePost(C139Constants.shareListURL, plain: plain, authorization: nil, signed: false)
        try Self.checkShare(json, fallback: "获取文件列表失败")
        guard let data = json.child("data") else { return [] }
        let folders = data.objects("caLst").map {
            DriveFile(id: $0.string("caID"), name: $0.string("caName"), size: 0, isDirectory: true, parentId: parentId,
                      modifiedAt: $0.string("udTime").ifBlank($0.string("ctTime")))
        }
        let files = data.objects("coLst").map {
            DriveFile(id: $0.string("coID"), name: $0.string("coName"), size: $0.int64("coSize"),
                      isDirectory: $0.has("isdir") ? $0.bool("isdir") : (($0.has("coType") ? $0.int("coType") : 1) == 2),
                      parentId: parentId, modifiedAt: $0.string("udTime").ifBlank($0.string("ctTime")))
        }
        return folders + files
    }

    /// dlFromOutLinkV3: `data.redrUrl`, an OBS link valid for 900 seconds. The response has no usable file name
    /// unless `fileName` or `coName` is present; the caller should pass the listed name on.
    public func getShareDownloadLink(coId: String, linkId: String, account: String, authorization: String?) async throws -> C139DownloadLink? {
        let request: [String: Any] = [
            "account": account, "linkID": linkId, "coIDLst": ["item": [coId]],
            "commonAccountInfo": ["account": account, "accountType": 1] as [String: Any],
        ]
        let plain = try Self.jsonString(["dlFromOutLinkReqV3": request])
        let json = try await sharePost(C139Constants.shareLinkURL, plain: plain, authorization: authorization, signed: true)
        try Self.checkShare(json, fallback: "获取下载链接失败")
        guard let data = json.child("data") else { return nil }
        let url = data.string("redrUrl")
        if url.isBlankText { return nil }
        let size = data.has("coSize") ? data.int64("coSize") : data.int64("size")
        return C139DownloadLink(fid: coId, filename: data.string("fileName").ifEmpty(data.string("coName").ifEmpty(coId)),
                                downloadURL: url, size: size)
    }

    // MARK: Share transfer

    /// Starts a transfer into `toFolderId` and returns the task id (prefixed `sk`), or nil when none came back.
    public func createTransferTask(coIds: [String], catalogIds: [String], toFolderId: String, linkId: String, account: String, authorization: String?) async throws -> String? {
        let taskInfo: [String: Any] = [
            "contentInfoList": coIds.map { "/\($0)" }, "catalogInfoList": catalogIds,
            "newCatalogID": toFolderId, "linkID": linkId, "newCatalogName": "手机图片", "needPassword": true,
        ]
        let request: [String: Any] = [
            "createOuterLinkBatchOprTaskReq": [
                "msisdn": account, "ownerAccount": "", "taskType": 1, "taskInfo": taskInfo,
                "linkID": linkId, "needPassword": true,
            ] as [String: Any],
            "commonAccountInfo": ["account": account, "accountType": 1] as [String: Any],
        ]
        let json = try await sharePost(C139Constants.transferCreateURL, plain: try Self.jsonString(request), authorization: authorization, signed: true)
        try Self.checkTransfer(json, fallback: "创建转存任务失败")
        return json.child("data")?.string("taskID").nonBlank
    }

    public func queryTransferTask(taskId: String, account: String, authorization: String?) async throws -> C139TransferResult {
        let request: [String: Any] = [
            "queryBatchOprTaskDetailReq": [
                "taskID": taskId, "msisdn": account,
                "commonAccountInfo": ["account": account, "accountType": 1] as [String: Any],
            ] as [String: Any],
        ]
        let json = try await sharePost(C139Constants.transferQueryURL, plain: try Self.jsonString(request), authorization: authorization, signed: true)
        try Self.checkTransfer(json, fallback: "查询转存结果失败")
        guard let data = json.child("data") else { return C139TransferResult(done: false, mapping: [:]) }
        let task = data.child("batchOprTask")
        let done = (task?.int("progress") ?? 0) >= 100 && (task?.int("taskStatus") ?? 0) == 2
        var mapping: [String: String] = [:]
        for item in data.child("contentList")?.objects("idRspInfo") ?? [] where item.string("reason") == "0000" {
            mapping[item.string("srcId")] = item.string("rstId")
        }
        return C139TransferResult(done: done, mapping: mapping)
    }

    // MARK: Personal drive

    /// 100 per page, newest first. Pass the previous page's cursor to continue; the root is "/".
    public func listCloudFiles(parentId: String, cookie: String, cursor: String? = nil) async throws -> C139FilePage {
        let authorization = try Self.requireAuthorization(cookie)
        let body = try Self.jsonString(listBody(parentId: parentId, cursor: cursor, foldersOnly: false))
        let json = try await cloudPost(C139Constants.fileListURL, body: body, authorization: authorization)
        try Self.checkCloud(json, fallback: "获取文件列表失败")
        guard let data = json.child("data") else { return C139FilePage(files: [], nextCursor: nil) }
        let files = data.objects("items").map {
            DriveFile(id: $0.string("fileId"), name: $0.string("name"), size: $0.int64("size"), isDirectory: $0.string("type") == "folder",
                      parentId: parentId, fileToken: $0.string("fileId"), modifiedAt: $0.string("updatedAt"))
        }
        return C139FilePage(files: files, nextCursor: data.string("nextPageCursor").nonBlank)
    }

    /// Folders only, first page: the pick-a-destination list.
    public func listFolders(parentId: String, cookie: String) async throws -> [DriveFile] {
        let authorization = try Self.requireAuthorization(cookie)
        let body = try Self.jsonString(listBody(parentId: parentId, cursor: nil, foldersOnly: true))
        let json = try await cloudPost(C139Constants.fileListURL, body: body, authorization: authorization)
        try Self.checkCloud(json, fallback: "获取文件夹列表失败")
        return (json.child("data")?.objects("items") ?? []).map {
            DriveFile(id: $0.string("fileId"), name: $0.string("name"), size: 0, isDirectory: true,
                      parentId: parentId, fileToken: $0.string("fileId"), modifiedAt: $0.string("updatedAt"))
        }
    }

    /// New folder; the server renames on a clash (`force_rename`). Returns its fileId.
    public func createFolder(parentId: String, name: String, cookie: String) async throws -> String {
        let authorization = try Self.requireAuthorization(cookie)
        let body = try Self.jsonString(["parentFileId": parentId, "name": name, "description": "", "type": "folder", "fileRenameMode": "force_rename"])
        let json = try await cloudPost(C139Constants.fileCreateURL, body: body, authorization: authorization)
        try Self.checkCloud(json, fallback: "新建文件夹失败")
        guard let id = json.child("data")?.string("fileId").nonBlank else { throw DriveError.api(message: "移动云盘未返回文件夹编号") }
        return id
    }

    public func renameFile(fileId: String, newName: String, cookie: String) async throws {
        let authorization = try Self.requireAuthorization(cookie)
        let body = try Self.jsonString(["fileId": fileId, "name": newName, "description": ""])
        try Self.checkCloud(try await cloudPost(C139Constants.fileUpdateURL, body: body, authorization: authorization), fallback: "重命名失败")
    }

    /// Asynchronous; returns the task id to poll with `getTask`.
    public func moveFiles(fileIds: [String], toParentId: String, cookie: String) async throws -> String? {
        let authorization = try Self.requireAuthorization(cookie)
        let body = try Self.jsonString(["fileIds": fileIds, "toParentFileId": toParentId])
        let json = try await cloudPost(C139Constants.batchMoveURL, body: body, authorization: authorization)
        try Self.checkCloud(json, fallback: "移动失败")
        return json.child("data")?.string("taskId").nonBlank
    }

    /// Moves to the recycle bin. Asynchronous; returns the task id.
    public func deleteFiles(fileIds: [String], cookie: String) async throws -> String? {
        let authorization = try Self.requireAuthorization(cookie)
        let json = try await cloudPost(C139Constants.batchTrashURL, body: try Self.jsonString(["fileIds": fileIds]), authorization: authorization)
        try Self.checkCloud(json, fallback: "删除失败")
        return json.child("data")?.string("taskId").nonBlank
    }

    public func getTask(taskId: String, cookie: String) async throws -> C139TaskStatus {
        let authorization = try Self.requireAuthorization(cookie)
        let json = try await cloudPost(C139Constants.taskGetURL, body: try Self.jsonString(["taskId": taskId]), authorization: authorization)
        try Self.checkCloud(json, fallback: "查询任务失败")
        guard let data = json.child("data") else { return C139TaskStatus(status: "", progress: 0, results: []) }
        let info = data.child("taskInfo")
        return C139TaskStatus(status: info?.string("status") ?? "", progress: info?.int("progress") ?? 0,
                              results: data.objects("batchFileResults").map { ($0.string("fileId"), $0.string("errCode")) })
    }

    /// OBS link valid for 900 seconds. The response has no file name; `filename` is empty then.
    public func getDownloadLink(fileId: String, cookie: String) async throws -> C139DownloadLink? {
        let authorization = try Self.requireAuthorization(cookie)
        let json = try await cloudPost(C139Constants.downloadURL, body: try Self.jsonString(["fileId": fileId]), authorization: authorization)
        try Self.checkCloud(json, fallback: "获取下载链接失败")
        guard let data = json.child("data") else { return nil }
        let url = data.string("url")
        if url.isBlankText { return nil }
        return C139DownloadLink(fid: fileId, filename: data.string("name"), downloadURL: url, size: data.int64("size"))
    }

    /// getOutLink; the passcode is generated by the server.
    /// - Parameter periodDays: nil for forever (no `period` field), else 1, 7 or 30. This is a day count, not a UI code.
    public func createShare(fileIds: [String], folderIds: [String], periodDays: Int?, name: String, cookie: String) async throws -> C139ShareInfo {
        let authorization = try Self.requireAuthorization(cookie)
        guard let account = C139CookieUtil.account(fromAuthorization: authorization) else {
            throw DriveError.api(message: "无法从登录态解析账号，请重新登录")
        }
        var request: [String: Any] = [
            "subLinkType": 0, "encrypt": 1, "coIDLst": fileIds, "caIDLst": folderIds, "pubType": 1,
            "dedicatedName": name, "periodUnit": 1, "viewerLst": [Any](),
            "extInfo": ["isWatermark": 0, "shareChannel": "3001"] as [String: Any],
            "commonAccountInfo": ["account": account, "accountType": 1] as [String: Any],
        ]
        if let periodDays { request["period"] = periodDays }
        let json = try await cloudPost(C139Constants.outlinkCreateURL, body: try Self.jsonString(["getOutLinkReq": request]),
                                       authorization: authorization, cookie: cookie, needsSkey: true)
        // This endpoint's success code is "0" only.
        if !Self.successFlag(json) || json.string("code") != "0" {
            throw DriveError.api(message: json.string("message").ifBlank("创建分享失败"), code: json.int("code"))
        }
        guard let set = json.child("data")?.child("getOutLinkRes")?.objects("getOutLinkResSet").first else {
            throw DriveError.api(message: "创建分享失败：未返回链接")
        }
        let url = set.string("linkUrl")
        if url.isBlankText { throw DriveError.api(message: "创建分享失败：未返回链接") }
        let expired: Int
        switch periodDays {
        case nil: expired = 1
        case 1: expired = 2
        case 7: expired = 3
        case 30: expired = 4
        default: expired = 0
        }
        return C139ShareInfo(shareURL: url, passcode: set.string("passwd"), linkId: set.string("linkID"), title: name, expiredType: expired)
    }

    /// user/disk/quota/detail. Sizes come in MB; used is quotaList[0].usedSize, else total minus free. nil on any failure.
    public func getQuota(cookie: String) async -> DriveQuota? {
        guard let authorization = C139Constants.extractAuthorization(cookie),
              let account = C139CookieUtil.account(fromAuthorization: authorization) else { return nil }
        let request: [String: Any] = ["userDomainId": "", "commonAccountInfo": ["account": account, "accountType": 1] as [String: Any]]
        guard let body = try? Self.jsonString(request),
              let json = try? await cloudPost(C139Constants.quotaURL, body: body, authorization: authorization, cookie: cookie, needsSkey: true),
              (try? Self.checkCloud(json, fallback: "获取空间详情失败")) != nil,
              let data = json.child("data") else { return nil }
        let megabyte: Int64 = 1024 * 1024
        let total = data.int64("diskSize") * megabyte
        let used = data.objects("quotaList").first.map { $0.int64("usedSize") * megabyte } ?? (total - data.int64("freeDiskSize") * megabyte)
        return DriveQuota(used: used, total: total)
    }

    // MARK: Requests

    private func listBody(parentId: String, cursor: String?, foldersOnly: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "pageInfo": ["pageSize": 100, "pageCursor": cursor.map { $0 as Any } ?? NSNull()] as [String: Any],
            "orderBy": "updated_at", "orderDirection": "DESC", "parentFileId": parentId,
            "imageThumbnailStyleList": ["Small", "Large"],
        ]
        if foldersOnly { body["type"] = "folder" }
        return body
    }

    /// Personal-drive POST: plain JSON, Authorization and mcloud-sign over the exact body sent. The full channel header set
    /// is mandatory; the gateway answers 404 / 04000005 without it. Cookie and mcloud-skey are added when asked for.
    private func cloudPost(_ url: String, body: String, authorization: String, cookie: String? = nil, needsSkey: Bool = false) async throws -> LenientJSON {
        var headers: [String: String] = [
            "Authorization": authorization,
            "mcloud-sign": signHeader(body),
            "x-yun-channel-source": C139Constants.yunChannelSource,
            "x-yun-app-channel": C139Constants.yunChannelSource,
            "x-huawei-channelSrc": C139Constants.yunChannelSource,
            "mcloud-version": C139Constants.mcloudVersion,
            "mcloud-client": C139Constants.mcloudClient,
            "mcloud-channel": C139Constants.mcloudChannel,
            "mcloud-route": "001",
            "x-yun-module-type": C139Constants.yunModuleType,
            "x-yun-api-version": "v1",
            "x-yun-svc-type": "1",
            "x-SvcType": "1",
            "caller": "web",
            "x-inner-ntwk": "2",
            "CMS-DEVICE": "default",
            "x-m4c-src": C139Constants.m4cSrc,
            "x-m4c-caller": C139Constants.m4cCaller,
            "X-Deviceinfo": C139Constants.xDeviceinfo,
            "x-yun-client-info": C139Constants.xClientInfo,
            "INNER-HCY-ROUTER-HTTPS": "1",
            "Sec-Fetch-Site": "same-site",
            "Sec-Fetch-Mode": "cors",
            "Sec-Fetch-Dest": "empty",
            "X-Requested-With": "mark.via",
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": C139Constants.pcUserAgent,
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/",
            "Accept": "application/json, text/plain, */*",
        ]
        if let cookie {
            headers["Cookie"] = cookie
            if needsSkey, let skey = C139CookieUtil.value(of: "skey", in: cookie) { headers["mcloud-skey"] = skey }
        }
        let response = try await send(url, headers: headers, body: body)
        return try Self.parsePlain(response)
    }

    /// Share POST: the body goes out encrypted and `hcy-cool-flag: 1` tells the gateway to decrypt it (without it: 9530).
    /// A plain-JSON answer, which the gateway sometimes passes through, is accepted too.
    private func sharePost(_ url: String, plain: String, authorization: String?, signed: Bool) async throws -> LenientJSON {
        var headers: [String: String] = [
            "hcy-cool-flag": "1",
            "x-deviceinfo": C139Constants.shareXDeviceinfo,
            "x-huawei-channelsrc": C139Constants.shareXHuaweiChannelsrc,
            "x-mm-source": C139Constants.shareXMMSource,
            "Content-Type": "application/json;charset=UTF-8",
            "User-Agent": C139Constants.shareMobileUserAgent,
            "Origin": "https://yun.139.com",
            "Referer": "https://yun.139.com/",
            "Accept": "application/json, text/plain, */*",
        ]
        if signed {
            if let authorization, !authorization.isBlankText { headers["Authorization"] = authorization }
            headers["mcloud-sign"] = signHeader(plain)
        }
        let encrypted = try C139Crypto.encryptBody(plain, iv: environment.iv())
        let response = try await send(url, headers: headers, body: encrypted)
        guard !response.body.isEmpty else { throw DriveError.api(message: "请求失败：响应为空") }
        let text = String(decoding: response.body, as: UTF8.self)
        if let decrypted = try? C139Crypto.decryptBody(text), let json = LenientJSON(data: Data(decrypted.utf8)) { return json }
        if let json = LenientJSON(data: response.body) { return json }
        throw DriveError.api(message: "响应解析失败（HTTP \(response.statusCode)）")
    }

    private func send(_ url: String, headers: [String: String], body: String) async throws -> HTTPResponse {
        guard let parsed = URL(string: url) else { throw DriveError.api(message: "请求地址无效") }
        return try await transport.send(HTTPRequest(method: .post, url: parsed, headers: headers, body: Data(body.utf8)))
    }

    // MARK: Responses

    private static func parsePlain(_ response: HTTPResponse) throws -> LenientJSON {
        guard !response.body.isEmpty else { throw DriveError.api(message: "请求失败：响应为空") }
        guard let json = LenientJSON(data: response.body) else {
            throw DriveError.api(message: "响应解析失败（HTTP \(response.statusCode)）")
        }
        return json
    }

    /// org.json's `optBoolean("success", true)`.
    private static func successFlag(_ json: LenientJSON) -> Bool { json.has("success") ? json.bool("success") : true }

    /// Share endpoints: `resultCode` "0" or absent, and `success` not false. `desc` is the server's reason.
    private static func checkShare(_ json: LenientJSON, fallback: String) throws {
        let code = json.string("resultCode")
        if !code.isBlankText, code != "0" {
            throw DriveError.api(message: json.string("desc").ifBlank("\(fallback)（\(code)）"), code: Int(code) ?? 0)
        }
        if !successFlag(json) { throw DriveError.api(message: json.string("desc").ifBlank(fallback)) }
    }

    /// Transfer endpoints report in `resultCode` or, failing that, `code`.
    private static func checkTransfer(_ json: LenientJSON, fallback: String) throws {
        let code = json.string("resultCode").ifBlank(json.string("code"))
        if !code.isBlankText, code != "0" {
            throw DriveError.api(message: json.string("desc").ifBlank("\(fallback)（\(code)）"), code: Int(code) ?? 0)
        }
    }

    /// Personal-drive endpoints: `success` not false and `code` "0000" or "0".
    private static func checkCloud(_ json: LenientJSON, fallback: String) throws {
        let code = json.string("code")
        if successFlag(json), code == "0000" || code == "0" { return }
        throw DriveError.api(message: "\(json.string("message").ifBlank(fallback))（code=\(code)）", code: Int(code) ?? 0)
    }

    private static func requireAuthorization(_ cookie: String) throws -> String {
        guard let authorization = C139Constants.extractAuthorization(cookie) else { throw DriveError.api(message: missingAuthorization) }
        return authorization
    }

    /// The body that is both sent and signed. Keys are sorted so the string is stable.
    static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}
