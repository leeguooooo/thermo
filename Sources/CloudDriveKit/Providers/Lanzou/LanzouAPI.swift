// Ported from YunX-Desktop (MIT): data/network/LanzouApi.kt.
// Endpoints, form fields, page parsing and error messages follow that file. Where the Kotlin
// control flow could not do what its comments say, the intended behaviour is implemented and
// the spot is marked "differs from source".
import Foundation

/// uid and vei from mydisk.php. vei is bound to the login session, so it is kept out of printed output.
public struct LanzouLoginParams: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let uid: String
    public let vei: String
    public var description: String { "LanzouLoginParams(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// lx, fid, t and k from the share page, used to page a folder share.
public struct LanzouFolderParams: Sendable, Equatable {
    public let lx: String
    public let fid: String
    public let t: String
    public let k: String
}

/// A parsed share page, cached by the provider so listing and link resolution reuse it.
public struct LanzouSharePage: Sendable, Equatable {
    public let shareURL: String
    public let baseURL: String
    public let title: String
    public let isFolder: Bool
    public let needsPasscode: Bool
    public let iframeURL: String?
    public let fileId: String?
    public let folderParams: LanzouFolderParams?
    public let html: String
    public let singleFile: DriveFile?
}

public struct LanzouShareInfo: Sendable, Equatable {
    public let shareURL: String
    public let passcode: String
    public let pwdId: String
}

public struct LanzouDownloadLink: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let fid: String
    public let filename: String
    public let downloadURL: String
    public let size: Int64
    public var description: String { "LanzouDownloadLink(\(fid), \(filename), <redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: ["fid": fid, "filename": filename, "size": size]) }
}

/// Small NSRegularExpression helpers standing in for Kotlin's Regex.
enum LanzouText {
    static func match(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options),
              let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return groups(found, in: text)
    }

    static func first(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> String? {
        guard let all = match(pattern, in: text, options: options), all.count > 1 else { return nil }
        return all[1]
    }

    static func all(_ pattern: String, in text: String, options: NSRegularExpression.Options = []) -> [[String?]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { groups($0, in: text) }
    }

    private static func groups(_ match: NSTextCheckingResult, in text: String) -> [String?] {
        (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } }
    }

    static func string(_ data: Data) -> String { String(decoding: data, as: UTF8.self) }

    static func substringAfterLast(_ text: String, _ separator: Character) -> String {
        guard let index = text.lastIndex(of: separator) else { return text }
        return String(text[text.index(after: index)...])
    }

    static func trimmed(_ text: String, _ character: Character) -> String {
        var result = Substring(text)
        while result.first == character { result.removeFirst() }
        while result.last == character { result.removeLast() }
        return String(result)
    }
}

public actor LanzouAPI {
    private let http: HTTPClient
    private let sleep: DriveSleeper

    /// Cookies computed locally per host (acw_sc__v2, down_ip). In memory only; they are not account credentials.
    private var hostCookies: [String: [(name: String, value: String)]] = [:]

    public init(transport: any HTTPTransport = URLSessionTransport(),
                sleep: @escaping DriveSleeper = { try await Task.sleep(nanoseconds: $0) }) {
        http = HTTPClient(transport: transport, defaultHeaders: ["User-Agent": LanzouConstants.webUserAgent])
        self.sleep = sleep
    }

    // MARK: Cookie jar

    private func hostOf(_ url: String) -> String { URL(string: url)?.host ?? "" }

    private func setCookie(host: String, name: String, value: String) {
        guard !host.isEmpty else { return }
        var cookies = hostCookies[host] ?? []
        if let index = cookies.firstIndex(where: { $0.name == name }) {
            cookies[index].value = value
        } else {
            cookies.append((name, value))
        }
        hostCookies[host] = cookies
    }

    private func cookieHeader(_ host: String) -> String {
        (hostCookies[host] ?? []).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func mergedCookie(_ host: String, extra: String?) -> String {
        [cookieHeader(host).nonBlank, extra?.nonBlank].compactMap { $0 }.joined(separator: "; ")
    }

    // MARK: Personal drive

    /// Extracts uid and vei from mydisk.php.
    public func fetchLoginParams(cookie: String) async throws -> LanzouLoginParams {
        let response = try await perform(.get, LanzouConstants.mydiskFilesURL, headers: [
            "Cookie": cookie, "Referer": LanzouConstants.mydiskURL, "Origin": LanzouConstants.origin,
        ], follow: true)
        guard (200..<300).contains(response.statusCode) else { throw DriveError.api(message: "蓝奏登录态无效，请重新登录") }
        let html = LanzouText.string(response.body)
        // The page holds url:'/doupload.php?uid=4133097', data:{ 'vei':'B1UHVFBWVQgFB1JWAFo=' }.
        let uid = LanzouText.first(#"uid['"]?\s*[=:]\s*['"]?(\d{1,20})"#, in: html)
        let vei = LanzouText.first(#"vei['"]?\s*[=:]\s*['"]?([A-Za-z0-9_\-+/=]{1,256})"#, in: html)
        guard let uid, !uid.isBlankText, let vei, !vei.isBlankText else { throw DriveError.api(message: "蓝奏登录态无效，请重新登录") }
        return LanzouLoginParams(uid: uid, vei: vei)
    }

    /// Account and password login on accounts.woozooo.com. Returns the pc.woozooo.com cookie string.
    /// 1) POST accounts.php (task=uselogin); a script challenge page (`arg1`) is answered with acw_sc__v2 and retried up to 4 times.
    /// 2) `{zt:'1', msgs:<hand-off URL>}`: GET msgs, then the files page, which fixes PHPSESSID (vei is bound to it).
    /// The password only goes into the request body; nothing is logged or kept.
    public func login(account: String, password: String) async throws -> String {
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || password.isEmpty { throw DriveError.api(message: "请输入蓝奏云账号和密码") }
        var jar: [String: [(name: String, value: String)]] = [:]
        let loginHeaders = [
            "Origin": LanzouConstants.accountsOrigin,
            "Referer": "\(LanzouConstants.accountsOrigin)/accounts.php?action=login&ref=\(LanzouConstants.loginRef)",
            "X-Requested-With": "XMLHttpRequest",
            "Accept": "application/json, text/javascript, */*; q=0.01",
        ]
        func postLogin(_ jar: inout [String: [(name: String, value: String)]]) async throws -> String {
            try await followingRedirects(.post, LanzouConstants.accountsURL, headers: loginHeaders, jar: &jar, fields: [
                ("task", "uselogin"), ("username", name), ("password", password), ("ref", LanzouConstants.loginRef),
            ])
        }

        var body = try await postLogin(&jar)
        var attempt = 0
        while attempt < 4, body.contains("arg1="), !body.contains("\"zt\"") {
            guard let arg1 = LanzouText.first(#"arg1\s*=\s*'([0-9A-Fa-f]{40})'"#, in: body) else { break }
            Self.store(&jar, host: "accounts.woozooo.com", name: "acw_sc__v2", value: LanzouCrypto.acwScV2(arg1))
            body = try await postLogin(&jar)
            attempt += 1
        }

        guard let json = LenientJSON(data: Data(body.utf8)) else { throw DriveError.api(message: "蓝奏云登录失败，请稍后重试") }
        guard json.string("zt") == "1" else {
            throw DriveError.api(message: json.string("msgs").nonBlank ?? "蓝奏云登录失败，请检查账号密码")
        }
        if let msgs = json.string("msgs").nonBlank {
            _ = try? await followingRedirects(.get, msgs, headers: ["Referer": "\(LanzouConstants.accountsOrigin)/"], jar: &jar, fields: nil)
            _ = try? await followingRedirects(.get, LanzouConstants.mydiskFilesURL, headers: ["Referer": LanzouConstants.mydiskURL], jar: &jar, fields: nil)
        }
        let cookie = (jar["pc.woozooo.com"] ?? []).map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        guard cookie.contains("ylogin"), cookie.contains("phpdisk_info") else {
            throw DriveError.api(message: "蓝奏云登录未获取到有效凭据，请重试")
        }
        return cookie
    }

    /// Lists a personal-drive directory: folders (task=47) then files (task=5).
    public func listCloudFiles(cookie: String, params: LanzouLoginParams, folderId: String) async throws -> [DriveFile] {
        var result: [DriveFile] = []
        let folderJSON = try await doupload(cookie, params, [("task", "47"), ("folder_id", folderId)], allowEnd: true)
        for item in folderJSON.objects("text") {
            let id = Self.firstNonBlank(item.string("fol_id"), item.string("id"))
            if id.isEmpty { continue }
            result.append(DriveFile(id: LanzouConstants.folderPrefix + id,
                                    name: Self.firstNonBlank(item.string("name"), item.string("name_all")),
                                    size: 0, isDirectory: true, parentId: folderId, modifiedAt: item.string("time")))
        }
        var seen = Set<String>()
        var page = 1
        while page <= LanzouConstants.maxFilePages {
            let json = try await doupload(cookie, params, [("task", "5"), ("folder_id", folderId), ("pg", String(page))], allowEnd: true)
            guard let array = json.array("text"), !array.isEmpty else { break }
            var added = 0
            for item in json.objects("text") {
                let id = item.string("id")
                if id.isBlankText || !seen.insert(id).inserted { continue }
                result.append(DriveFile(id: LanzouConstants.filePrefix + id,
                                        name: Self.firstNonBlank(item.string("name_all"), item.string("name")),
                                        size: Self.parseDisplaySize(item.string("size")),
                                        isDirectory: false, parentId: folderId, modifiedAt: item.string("time")))
                added += 1
            }
            if added == 0 { throw DriveError.api(message: "蓝奏文件分页重复，请刷新后重试") }
            page += 1
        }
        return result
    }

    /// Creates a folder and returns its id.
    public func createFolder(cookie: String, params: LanzouLoginParams, parentId: String, name: String) async throws -> String {
        let json = try await doupload(cookie, params, [
            ("task", "2"), ("parent_id", parentId), ("folder_name", name), ("folder_description", ""),
        ])
        let text = json.string("text")
        guard !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { throw DriveError.api(message: "蓝奏未返回新文件夹信息") }
        return text
    }

    public func renameFolder(cookie: String, params: LanzouLoginParams, folderId: String, newName: String) async throws {
        _ = try await doupload(cookie, params, [
            ("task", "4"), ("folder_id", folderId), ("folder_name", newName), ("folder_description", ""),
        ])
    }

    public func renameFile(cookie: String, params: LanzouLoginParams, fileId: String, newName: String) async throws {
        _ = try await doupload(cookie, params, [("task", "46"), ("file_id", fileId), ("file_name", newName), ("type", "2")])
    }

    /// Moves one file.
    public func moveFile(cookie: String, params: LanzouLoginParams, folderId: String, fileId: String) async throws {
        _ = try await doupload(cookie, params, [("task", "20"), ("folder_id", folderId), ("file_id", fileId)])
    }

    public func deleteFolder(cookie: String, params: LanzouLoginParams, folderId: String) async throws {
        _ = try await doupload(cookie, params, [("task", "3"), ("folder_id", folderId)])
    }

    public func deleteFile(cookie: String, params: LanzouLoginParams, fileId: String) async throws {
        _ = try await doupload(cookie, params, [("task", "6"), ("file_id", fileId)])
    }

    public func createFileShare(cookie: String, params: LanzouLoginParams, fileId: String) async throws -> LanzouShareInfo {
        let json = try await doupload(cookie, params, [("task", "22"), ("file_id", fileId)])
        guard let info = json.child("info") else { throw DriveError.api(message: "蓝奏未返回分享链接") }
        return Self.shareInfo(raw: info.string("f_id"), domain: info.string("is_newd"), passcode: info.string("pwd"))
    }

    public func createFolderShare(cookie: String, params: LanzouLoginParams, folderId: String) async throws -> LanzouShareInfo {
        let json = try await doupload(cookie, params, [("task", "18"), ("file_id", folderId)])
        guard let info = json.child("info") else { throw DriveError.api(message: "蓝奏未返回分享链接") }
        return Self.shareInfo(raw: info.string("new_url"), domain: info.string("is_newd"), passcode: info.string("pwd"))
    }

    // MARK: Anonymous share

    /// Fetches and parses a share page (folder or single file).
    public func resolveShare(_ shareURL: String, passcode: String?) async throws -> LanzouSharePage {
        let normalized = LanzouConstants.normalizeShareURL(shareURL)
        guard let url = URL(string: normalized), let scheme = url.scheme, let host = url.host,
              LanzouConstants.isLanzouHost(host) else { throw DriveError.api(message: "蓝奏分享链接无效") }
        let html = try await fetchPageFollowingLanzou(normalized)
        let origin = "\(scheme)://\(host)"
        let title = Self.extractTitle(html)
        let needsPasscode = html.contains("请输入密码") || html.contains("id=\"pwbox\"") || html.contains("input_password") || html.contains("密码不正确")
        let isFolder = html.contains("filemoreajax") || html.contains("class=\"filemore\"") || html.contains("file_more")
        let iframeURL = LanzouText.first(#"<iframe[^>]+src=["']([^"']+)["']"#, in: html).map { Self.absolutize(origin, $0) }
        let fileId = LanzouText.first(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
            ?? LanzouText.first(#"name=["']file["']\s+value=["'](\d+)["']"#, in: html)
            ?? LanzouText.first(#"file=(\d+)"#, in: html)
        var folderParams: LanzouFolderParams?
        if isFolder {
            let lx = Self.jsVar(html, "lx")
            let fid = Self.jsVar(html, "fid") ?? LanzouText.substringAfterLast(url.path, "/")
            let t = Self.jsVar(html, "t")
            let k = Self.jsVar(html, "k")
            if let lx, let t, let k { folderParams = LanzouFolderParams(lx: lx, fid: fid, t: t, k: k) }
        }
        let trimmedPath = LanzouText.trimmed(url.path, "/")
        let shareId = LanzouText.substringAfterLast(trimmedPath, "/").ifBlank(trimmedPath)
        // A single-file share shows its size as page text such as "文件大小：1.5 M".
        let displaySize = LanzouText.match(#"(?:文件大小|大小)\s*[:：]\s*([\d.]+)\s*([KMGT]?)(?:i?B)?"#, in: html, options: .caseInsensitive)
            .map { Self.parseDisplaySize("\($0[1] ?? "") \($0[2] ?? "")") } ?? 0
        let singleFile: DriveFile? = isFolder ? nil
            : DriveFile(id: shareId, name: title, size: displaySize, isDirectory: false, parentId: "")
        return LanzouSharePage(shareURL: normalized, baseURL: origin, title: title.ifBlank("蓝奏分享"), isFolder: isFolder,
                               needsPasscode: needsPasscode, iframeURL: iframeURL, fileId: fileId,
                               folderParams: folderParams, html: html, singleFile: singleFile)
    }

    /// Pages a folder share through filemoreajax.php.
    /// Differs from source: LanzouApi.kt assigns the response inside `try { formPost(...); break }`, so the
    /// response is discarded and the listing comes back empty; the response is used here. Its zt=4 branch
    /// (`pg--`) never reached its own throw, so a rate-limited page is retried twice and then fails.
    public func listShareFolder(_ page: LanzouSharePage, passcode: String?) async throws -> [DriveFile] {
        guard let params = page.folderParams else { throw DriveError.api(message: "蓝奏分享分页异常，请重试") }
        var all: [DriveFile] = []
        var seen = Set<String>()
        var pageNumber = 1
        while pageNumber <= LanzouConstants.maxFolderPages {
            var retries = 0
            var body = try await fetchFolderPage(page, params, passcode, pageNumber)
            while Self.zt(body, default: 0) == 4 {
                if retries >= 2 { throw DriveError.api(message: "蓝奏请求过于频繁，请稍后再试") }
                retries += 1
                try await sleep(300_000_000)
                body = try await fetchFolderPage(page, params, passcode, pageNumber)
            }
            switch Self.zt(body, default: 0) {
            case 1: break
            case 2: return all
            case 3: throw DriveError.api(message: "蓝奏提取码错误，请检查后重新解析")
            default: throw DriveError.api(message: "蓝奏解析失败，请确认分享链接和提取码后重试")
            }
            guard let array = body.array("text"), !array.isEmpty else { break }
            var added = 0
            for item in body.objects("text") {
                let id = item.string("id")
                if id.isBlankText || !seen.insert(id).inserted { continue }
                all.append(DriveFile(id: id, name: Self.firstNonBlank(item.string("name_all"), item.string("name")),
                                     size: Self.parseDisplaySize(item.string("size")), isDirectory: false,
                                     parentId: "", modifiedAt: item.string("time")))
                added += 1
            }
            if added == 0 { throw DriveError.api(message: "蓝奏分页重复，请重新打开目录") }
            pageNumber += 1
        }
        return all
    }

    private func fetchFolderPage(_ page: LanzouSharePage, _ params: LanzouFolderParams, _ passcode: String?, _ number: Int) async throws -> LenientJSON {
        var failures = 0
        while true {
            do {
                return try await formPost("\(page.baseURL)/filemoreajax.php", [
                    ("lx", params.lx), ("fid", params.fid), ("t", params.t), ("k", params.k),
                    ("pwd", passcode ?? ""), ("pg", String(number)),
                ], referer: page.shareURL, origin: page.baseURL, cookie: nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failures += 1
                if failures > 2 { throw DriveError.api(message: "蓝奏请求过于频繁，请稍后再试") }
                try await sleep(300_000_000)
            }
        }
    }

    /// Resolves the direct link of a shared file without an account.
    public func getShareDownloadLink(_ page: LanzouSharePage, file: DriveFile, passcode: String?) async throws -> LanzouDownloadLink {
        let origin = page.baseURL
        // The download page is a same-origin iframe.
        var html = page.html
        if let iframe = page.iframeURL, let iframeHost = URL(string: iframe)?.host {
            if iframeHost.caseInsensitiveCompare(hostOf(page.shareURL)) == .orderedSame {
                html = try await fetchPage(iframe, referer: page.shareURL, cookie: nil)
            } else {
                throw DriveError.api(message: "蓝奏下载页面地址异常，请检查分享链接")
            }
        }
        guard let fileId = page.fileId
            ?? LanzouText.first(#"(?:ajaxm|ajaxfile)\.php\?file=(\d+)"#, in: html)
            ?? LanzouText.first(#"file=(\d+)"#, in: html) else {
            throw DriveError.api(message: "蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let passcode = passcode?.nonBlank
        // The endpoint may be same-origin or apifile.woozooo.com (newer pages give a full URL in domain1/domain2).
        let ajaxURL = Self.resolveAjaxURL(html, origin: origin, fileId: fileId, withPasscode: passcode != nil)
        // Newer pages name the signature wp_sign; older ones sign.
        guard let sign = Self.jsVar(html, "wp_sign") ?? Self.jsVar(html, "sign") ?? Self.inputValue(html, "sign") else {
            throw DriveError.api(message: "蓝奏分享页缺少下载参数，请重新解析")
        }
        let ajaxData = Self.jsVar(html, "ajaxdata")
        let kd = Self.jsVarRaw(html, "kdns") ?? "1"
        var fields: [(String, String)] = [("action", "downprocess"), ("sign", sign)]
        if let passcode {
            fields += [("p", passcode), ("kd", "1")]
        } else {
            // Newer no-passcode protocol: websignkey and signs come from ajaxdata, websign is empty, kd is kdns.
            let key = ajaxData ?? Self.jsVar(html, "websignkey") ?? Self.inputValue(html, "websignkey") ?? ""
            fields += [("signs", Self.jsVar(html, "signs") ?? key), ("websignkey", key),
                       ("websign", Self.jsVar(html, "websign") ?? ""), ("kd", kd), ("ves", "1")]
        }
        let ajax = try await formPost(ajaxURL, fields, referer: page.shareURL, origin: origin, cookie: nil)
        try Self.validateAjax(ajax)
        let dom = ajax.string("dom")
        let relative = ajax.string("url")
        if dom.isBlankText || relative.isBlankText || relative.hasPrefix("/") || relative.contains("://") {
            throw DriveError.api(message: "蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        guard let domURL = URL(string: dom), let scheme = domURL.scheme, let host = domURL.host else {
            throw DriveError.api(message: "蓝奏解析失败，请确认分享链接和提取码后重试")
        }
        let (finalURL, size) = try await probeAndVerify("\(scheme)://\(host)/file/\(relative)", shareOrigin: origin)
        return LanzouDownloadLink(fid: file.id, filename: file.name.ifBlank(ajax.string("inf")), downloadURL: finalURL, size: size)
    }

    /// Lanzou has no personal-drive link API: make a share link for the file (task=22), then use the anonymous path.
    public func getPersonalDownloadLink(cookie: String, params: LanzouLoginParams, fileId: String, fileName: String) async throws -> LanzouDownloadLink {
        let info = try await createFileShare(cookie: cookie, params: params, fileId: fileId)
        let page = try await resolveShare(info.shareURL, passcode: info.passcode)
        let file = page.singleFile ?? DriveFile(id: page.shareURL, name: fileName, size: 0, isDirectory: false, parentId: "")
        return try await getShareDownloadLink(page, file: file, passcode: info.passcode)
    }

    // MARK: Download node

    private func headerValue(_ response: HTTPResponse, _ name: String) -> String? {
        response.headers.first { $0.key.lowercased() == name.lowercased() }?.value
    }

    private func probeAndVerify(_ jump: String, shareOrigin: String) async throws -> (String, Int64) {
        var url = jump
        let unavailable = DriveError.api(message: "蓝奏下载地址暂时不可用，请稍后重试")
        // The download node needs the down_ip=1 cookie.
        setCookie(host: hostOf(jump), name: "down_ip", value: "1")
        var confirmedHosts = Set<String>()
        var challenges = Set<String>()
        var visited = Set<String>()
        for _ in 0..<8 {
            guard let parsed = URL(string: url), let scheme = parsed.scheme, let host = parsed.host else { throw unavailable }
            if !visited.insert(url).inserted { throw DriveError.api(message: "蓝奏下载地址循环跳转，请重新解析") }
            let response = try await headRequest(url, shareOrigin: shareOrigin)
            let code = response.statusCode
            switch code {
            case 300...399:
                guard let location = headerValue(response, "location") else { throw unavailable }
                url = Self.absolutize("\(scheme)://\(host)", location)
            case 200, 206:
                let size = headSize(response)
                let isHTML = (headerValue(response, "content-type") ?? "").contains("text/html")
                if isHTML {
                    let body = try await getText(url, referer: shareOrigin)
                    // The node may answer with an acw_sc__v2 challenge first: set the cookie and replay.
                    if let challenge = LanzouCrypto.challengeCookie(body) {
                        if !challenges.insert(host).inserted { throw DriveError.api(message: "蓝奏需要进一步验证，请在分享页完成验证后重试") }
                        setCookie(host: host, name: "acw_sc__v2", value: challenge)
                        // Differs from source: the same URL is replayed on purpose, which `visited` would otherwise reject as a loop.
                        visited.remove(url)
                        continue
                    }
                    if body.contains("验证并下载") {
                        if confirmedHosts.insert(host).inserted, let verified = try await submitVerify(url, html: body) {
                            url = verified
                            continue
                        }
                        throw DriveError.api(message: "蓝奏需要进一步验证，请在分享页完成验证后重试")
                    }
                    throw DriveError.api(message: "蓝奏返回的是验证页面，未创建下载任务，请在分享页完成验证后重试")
                }
                // HEAD gave no size: fall back to a ranged GET.
                if size <= 0 {
                    let fallback = try await rangeProbe(url, shareOrigin: shareOrigin)
                    if fallback > 0 { return (url, fallback) }
                }
                return (url, size)
            case 403, 404, 410:
                throw DriveError.api(message: "蓝奏下载地址已失效，请稍后重新解析")
            case 429:
                throw DriveError.api(message: "蓝奏下载请求过于频繁，请稍后再试")
            default:
                let fallback = try await rangeProbe(url, shareOrigin: shareOrigin)
                if fallback > 0 { return (url, fallback) }
                throw unavailable
            }
        }
        throw unavailable
    }

    private func headSize(_ response: HTTPResponse) -> Int64 {
        if let range = headerValue(response, "content-range") { return Int64(LanzouText.substringAfterLast(range, "/")) ?? 0 }
        if response.statusCode == 200 { return headerValue(response, "content-length").flatMap { Int64($0) } ?? 0 }
        return 0
    }

    /// Submits the "验证并下载" confirmation and returns the new link, or nil when the page has no usable parameters.
    private func submitVerify(_ nodeURL: String, html: String) async throws -> String? {
        guard let node = URL(string: nodeURL), let scheme = node.scheme, let host = node.host else { return nil }
        // Newer confirmation page: data : { 'file':'<base64>','el':el,'sign':'<base64>' }
        let dataMatch = LanzouText.all(#"data\s*:\s*\{([^{}]*(?:\{[^{}]*\}[^{}]*)*)\}"#, in: html, options: .dotMatchesLineSeparators)
            .compactMap { $0.count > 1 ? $0[1] : nil }
            .first { $0.contains("'file'") || $0.contains("\"file\"") }
        guard let file = dataMatch.flatMap({ LanzouText.first(#"['"]?file['"]?\s*:\s*['"]([^'"]+)['"]"#, in: $0) })
            ?? LanzouText.first(#"name=["']file["'][^>]*value=["']([^"']+)["']"#, in: html) else { return nil }
        guard let sign = dataMatch.flatMap({ LanzouText.first(#"['"]?sign['"]?\s*:\s*['"]([^'"]+)['"]"#, in: $0) })
            ?? Self.jsVar(html, "sign") ?? Self.inputValue(html, "sign") else { return nil }
        // The node shows its button after 2 seconds, so wait as long before submitting.
        try await sleep(2_000_000_000)
        let ajaxURL = URL(string: "ajax.php", relativeTo: node)?.absoluteString ?? "\(scheme)://\(host)/ajax.php"
        let json: LenientJSON
        do {
            json = try await formPost(ajaxURL, [("file", file), ("el", "2"), ("sign", sign)], referer: nodeURL, origin: "\(scheme)://\(host)", cookie: nil)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw DriveError.api(message: "蓝奏下载验证服务暂时不可用，请稍后重试")
        }
        let url = json.string("url")
        if Self.zt(json, default: 0) != 1 || url.isBlankText {
            // With zt != 1 the url field carries the error text, such as 验证码错误.
            throw DriveError.api(message: url.nonBlank ?? "蓝奏需要进一步验证，请在分享页完成验证后重试")
        }
        if url == "?SignError" { throw DriveError.api(message: "蓝奏下载验证已过期，请重新解析") }
        return url
    }

    private func headRequest(_ url: String, shareOrigin: String) async throws -> HTTPResponse {
        var headers = ["Referer": "\(shareOrigin)/"]
        let cookie = mergedCookie(hostOf(url), extra: LanzouConstants.downIPCookie)
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return try await perform(.head, url, headers: headers, follow: false)
    }

    private func rangeProbe(_ url: String, shareOrigin: String) async throws -> Int64 {
        var headers = ["Referer": "\(shareOrigin)/", "Range": "bytes=0-8191"]
        let cookie = mergedCookie(hostOf(url), extra: LanzouConstants.downIPCookie)
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        let response = try await perform(.get, url, headers: headers, follow: false)
        guard let range = headerValue(response, "content-range") else { return 0 }
        return Int64(LanzouText.substringAfterLast(range, "/")) ?? 0
    }

    private func getText(_ url: String, referer: String?) async throws -> String {
        var headers: [String: String] = [:]
        if let referer { headers["Referer"] = referer }
        let cookie = mergedCookie(hostOf(url), extra: LanzouConstants.downIPCookie)
        if !cookie.isEmpty { headers["Cookie"] = cookie }
        return LanzouText.string(try await perform(.get, url, headers: headers, follow: true).body)
    }

    // MARK: Pages

    /// Follows redirects by hand so every hop must stay on a Lanzou host.
    private func fetchPageFollowingLanzou(_ start: String) async throws -> String {
        var current = start
        var challenged = Set<String>()
        for _ in 0..<8 {
            let host = hostOf(current)
            var headers = ["Referer": current]
            if let cookie = cookieHeader(host).nonBlank { headers["Cookie"] = cookie }
            let response = try await perform(.get, current, headers: headers, follow: false)
            if (300...399).contains(response.statusCode) {
                guard let location = headerValue(response, "location") else { throw DriveError.api(message: "蓝奏页面跳转次数过多，请重新解析") }
                let next = Self.absolutize(current, location)
                guard let nextHost = URL(string: next)?.host, LanzouConstants.isLanzouHost(nextHost) else {
                    throw DriveError.api(message: "蓝奏分享链接无效")
                }
                current = next
                continue
            }
            if response.body.count > 2_000_000 { throw DriveError.api(message: "蓝奏分享页面过大或异常") }
            let body = LanzouText.string(response.body)
            // The share page may answer with an acw_sc__v2 challenge first: set the cookie and replay.
            if let challenge = LanzouCrypto.challengeCookie(body) {
                if !challenged.insert(host).inserted { throw DriveError.api(message: "蓝奏需要进一步验证，请在分享页完成验证后重试") }
                setCookie(host: host, name: "acw_sc__v2", value: challenge)
                continue
            }
            if body.contains("文件已取消") || body.contains("不存在") { throw DriveError.api(message: "蓝奏文件已取消分享或不存在") }
            if body.contains("请求过于频繁") || body.contains("稍后再试") { throw DriveError.api(message: "蓝奏请求过于频繁，请稍后再试") }
            return body
        }
        throw DriveError.api(message: "蓝奏页面跳转次数过多，请重新解析")
    }

    private func fetchPage(_ url: String, referer: String?, cookie: String?) async throws -> String {
        var headers = ["Referer": referer ?? url]
        if let merged = mergedCookie(hostOf(url), extra: cookie).nonBlank { headers["Cookie"] = merged }
        let response = try await perform(.get, url, headers: headers, follow: true)
        guard (200..<300).contains(response.statusCode) else { throw DriveError.api(message: "蓝奏文件已取消分享或不存在") }
        return LanzouText.string(response.body)
    }

    private static func validateAjax(_ json: LenientJSON) throws {
        if zt(json, default: 0) == 1 { return }
        let inf = json.string("inf")
        if inf.contains("密码") || inf.contains("提取码") { throw DriveError.api(message: "蓝奏提取码错误，请检查后重新解析") }
        if ["不存在", "取消", "过期", "删除"].contains(where: inf.contains) { throw DriveError.api(message: "蓝奏文件已取消分享或不存在") }
        if ["频繁", "次数", "稍后"].contains(where: inf.contains) { throw DriveError.api(message: "蓝奏请求过于频繁，请稍后再试") }
        throw DriveError.api(message: "蓝奏解析失败，请确认分享链接和提取码后重试")
    }

    // MARK: Requests

    /// doupload.php: one endpoint for every personal-drive task. With allowEnd, zt 2 (end of list) is success.
    private func doupload(_ cookie: String, _ params: LanzouLoginParams, _ fields: [(String, String)], allowEnd: Bool = false) async throws -> LenientJSON {
        let response = try await perform(.post, "\(LanzouConstants.douploadURL)?uid=\(params.uid)&vei=\(params.vei)", headers: [
            "Cookie": cookie, "Referer": LanzouConstants.mydiskURL, "Origin": LanzouConstants.origin,
            "X-Requested-With": "XMLHttpRequest",
        ], fields: fields, follow: true)
        if response.statusCode == 401 || response.statusCode == 403 { throw DriveError.api(message: "蓝奏登录已过期，请重新登录") }
        guard let json = LenientJSON(data: response.body) else {
            throw DriveError.api(message: "蓝奏文件操作失败，请在官网检查权限和文件类型")
        }
        let code = Self.zt(json, default: -1)
        switch code {
        case 1: return json
        case 2 where allowEnd: return json
        case 4: throw DriveError.api(message: "蓝奏请求频繁，请稍后重试")
        case 9: throw DriveError.api(message: "蓝奏登录已过期，请重新登录")
        default: throw DriveError.api(message: "蓝奏文件操作失败（\(code)），请在官网检查权限和文件类型")
        }
    }

    private func formPost(_ url: String, _ fields: [(String, String)], referer: String, origin: String, cookie: String?) async throws -> LenientJSON {
        var headers = ["Referer": referer, "Origin": origin, "X-Requested-With": "XMLHttpRequest"]
        if let merged = mergedCookie(hostOf(url), extra: cookie).nonBlank { headers["Cookie"] = merged }
        let response = try await perform(.post, url, headers: headers, fields: fields, follow: false)
        if response.statusCode == 429 { throw DriveError.api(message: "蓝奏请求过于频繁，请稍后再试") }
        if response.body.count > 4_000_000 { throw DriveError.api(message: "蓝奏解析服务返回内容过大，请稍后重试") }
        let success = (200..<300).contains(response.statusCode)
        let text = LanzouText.string(response.body)
        if !success, text.isBlankText { throw DriveError.api(message: "蓝奏解析服务响应异常（HTTP \(response.statusCode)），请稍后重试") }
        guard let json = LenientJSON(data: response.body) else {
            if text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") {
                throw DriveError.api(message: "蓝奏返回了验证页面，请稍后重试或在分享页完成验证")
            }
            throw DriveError.api(message: "蓝奏解析服务响应异常，请稍后重试")
        }
        return json
    }

    private func perform(_ method: HTTPMethod, _ url: String, headers: [String: String] = [:], fields: [(String, String)]? = nil, follow: Bool) async throws -> HTTPResponse {
        guard let parsed = URL(string: url) else { throw DriveError.api(message: "请求地址无效") }
        var merged = headers
        var body: Data?
        if let fields {
            merged["Content-Type"] = "application/x-www-form-urlencoded"
            body = Data(fields.map { "\(HTTPClient.encodeQueryValue($0.0))=\(HTTPClient.encodeQueryValue($0.1))" }.joined(separator: "&").utf8)
        }
        return try await http.execute(HTTPRequest(method: method, url: parsed, headers: merged, body: body, followRedirects: follow))
    }

    /// The login flow follows redirects itself, keeping a cookie jar per host as the source's CookieJar did.
    private func followingRedirects(_ method: HTTPMethod, _ start: String, headers: [String: String],
                                    jar: inout [String: [(name: String, value: String)]], fields: [(String, String)]?) async throws -> String {
        var current = start
        var method = method
        var fields = fields
        for _ in 0..<20 {
            guard let host = URL(string: current)?.host else { throw DriveError.api(message: "请求地址无效") }
            var requestHeaders = headers
            if let cookies = jar[host], !cookies.isEmpty { requestHeaders["Cookie"] = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ") }
            let response = try await perform(method, current, headers: requestHeaders, fields: fields, follow: false)
            for setCookie in response.setCookies {
                let pair = setCookie.split(separator: ";", maxSplits: 1).first.map(String.init) ?? setCookie
                guard let equals = pair.firstIndex(of: "="), equals != pair.startIndex else { continue }
                let name = String(pair[..<equals]).trimmingCharacters(in: .whitespaces)
                Self.store(&jar, host: host, name: name, value: String(pair[pair.index(after: equals)...]))
            }
            if [301, 302, 303, 307, 308].contains(response.statusCode), let location = headerValue(response, "location") {
                current = Self.absolutize(current, location)
                if response.statusCode != 307, response.statusCode != 308 { method = .get; fields = nil }
                continue
            }
            return LanzouText.string(response.body)
        }
        throw DriveError.api(message: "蓝奏页面跳转次数过多，请重新解析")
    }

    private static func store(_ jar: inout [String: [(name: String, value: String)]], host: String, name: String, value: String) {
        var cookies = jar[host] ?? []
        if let index = cookies.firstIndex(where: { $0.name == name }) { cookies[index].value = value } else { cookies.append((name, value)) }
        jar[host] = cookies
    }

    // MARK: Parsing

    /// org.json's optInt("zt", default): a missing key gives the default.
    private static func zt(_ json: LenientJSON, default fallback: Int) -> Int { json.has("zt") ? json.int("zt") : fallback }

    private static func shareInfo(raw: String, domain: String, passcode: String) -> LanzouShareInfo {
        let base: String
        if domain.isBlankText { base = LanzouConstants.defaultShareBase }
        else if domain.contains("://") { base = domain }
        else { base = "https://\(domain)" }
        let url: String
        if raw.contains("://") {
            url = raw
        } else {
            let origin = URL(string: base).flatMap { u in u.scheme.flatMap { s in u.host.map { "\(s)://\($0)" } } } ?? base
            var path = Substring(raw)
            while path.first == "/" { path.removeFirst() }
            url = "\(origin)/\(path)"
        }
        return LanzouShareInfo(shareURL: url, passcode: passcode, pwdId: raw)
    }

    private static func extractTitle(_ html: String) -> String {
        if let title = LanzouText.first(#"<title>([^<]*)</title>"#, in: html) {
            let clean = title.replacingOccurrences(of: " - 蓝奏云", with: "").replacingOccurrences(of: "蓝奏云", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isBlankText, !clean.contains("密码") { return clean }
        }
        if let name = LanzouText.first(#"class=["']n["']>([^<]+)<"#, in: html) { return name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if let name = LanzouText.first(#"var\s+filename\s*=\s*['"]([^'"]+)['"]"#, in: html) { return name }
        return ""
    }

    private static func jsVar(_ html: String, _ name: String) -> String? {
        LanzouText.first(#"(?:(?:var|let|const)\s+)?\#(name)\s*=\s*['"]([^'"]*)['"]"#, in: html)
    }

    /// An unquoted JS value such as `var kdns = 0`.
    private static func jsVarRaw(_ html: String, _ name: String) -> String? {
        LanzouText.first(#"(?:var|let|const)\s+\#(name)\s*=\s*([^;,\n\r]+)"#, in: html)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "'\"")) }
    }

    /// domain1/domain2 first (newer pages, cross-origin), then an absolute ajaxm/ajaxfile URL in the page, then same origin.
    private static func resolveAjaxURL(_ html: String, origin: String, fileId: String, withPasscode: Bool) -> String {
        if let candidate = jsVar(html, "domain1").flatMap({ $0.contains("/ajax") ? $0 : nil })
            ?? jsVar(html, "domain2").flatMap({ $0.contains("/ajax") ? $0 : nil })
            ?? LanzouText.match(#"https?://[^'"\s]+/(?:ajaxm|ajaxfile)\.php\?file=\d+"#, in: html)?.first.flatMap({ $0 }),
           !candidate.isBlankText {
            return candidate
        }
        return withPasscode ? "\(origin)/ajaxfile.php?file=\(fileId)" : "\(origin)/ajaxm.php?file=\(fileId)"
    }

    private static func inputValue(_ html: String, _ name: String) -> String? {
        LanzouText.first(#"<input[^>]*name=["']\#(name)["'][^>]*value=["']([^"']*)["']"#, in: html)
            ?? LanzouText.first(#"<input[^>]*value=["']([^"']*)["'][^>]*name=["']\#(name)["']"#, in: html)
    }

    static func absolutize(_ base: String, _ target: String) -> String {
        if target.hasPrefix("http://") || target.hasPrefix("https://") { return target }
        guard let url = URL(string: base), let scheme = url.scheme, let host = url.host else { return target }
        let root = "\(scheme)://\(host)"
        return target.hasPrefix("/") ? root + target : "\(root)/\(target)"
    }

    static func parseDisplaySize(_ text: String) -> Int64 {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return 0 }
        guard let found = LanzouText.match(#"([\d.]+)\s*([KMGT]?)"#, in: trimmed, options: .caseInsensitive),
              let number = found[1], let value = Double(number) else { return 0 }
        let factor: Double
        switch (found[2] ?? "").uppercased() {
        case "K": factor = 1024
        case "M": factor = 1024 * 1024
        case "G": factor = 1024 * 1024 * 1024
        case "T": factor = 1024 * 1024 * 1024 * 1024
        default: factor = 1
        }
        return Int64(value * factor)
    }

    private static func firstNonBlank(_ values: String...) -> String {
        values.first { !$0.isBlankText }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
