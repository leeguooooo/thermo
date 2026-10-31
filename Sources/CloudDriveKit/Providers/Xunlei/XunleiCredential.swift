// Ported from YunX-Desktop (MIT): data/network/XunleiWebCredential.kt (the parsing half) and the
// account fields of db/XunleiAccountEntity. The browser bridge scripts and the headless-session
// fallback are not ported.
import Foundation

/// Everything one Xunlei account needs, folded into the single string a `DriveCredential` carries.
/// The value is a JSON object, so the host stores it as one secret (Keychain) and never splits it.
public struct XunleiCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var accessToken: String
    public var refreshToken: String
    public var deviceId: String
    public var captchaToken: String
    public var userId: String
    public var nickname: String
    /// `XunleiWebAuth.authType` for tokens issued by pan.xunlei.com; empty for app tokens.
    public var authType: String

    public init(accessToken: String, refreshToken: String = "", deviceId: String = "", captchaToken: String = "",
                userId: String = "", nickname: String = "", authType: String = "") {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.deviceId = deviceId
        self.captchaToken = captchaToken
        self.userId = userId
        self.nickname = nickname
        self.authType = authType
    }

    public var isWeb: Bool { authType == XunleiWebAuth.authType }
    public var description: String { "XunleiCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    /// The value to hand to a provider. Blank fields are left out.
    public var driveCredential: DriveCredential {
        let fields: [String: String] = [
            "access_token": accessToken, "refresh_token": refreshToken, "device_id": deviceId,
            "captcha_token": captchaToken, "user_id": userId, "nick_name": nickname, "auth_type": authType,
        ].filter { !$0.value.isEmpty }
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return DriveCredential(String(decoding: data, as: UTF8.self))
    }

    /// Reads a stored credential, or anything `parse` accepts.
    public init?(_ credential: DriveCredential) {
        guard let parsed = Self.parse(credential.value) else { return nil }
        self = parsed
    }

    /// Reads what pan.xunlei.com keeps in localStorage (or a pasted token) and marks it as a web token,
    /// which changes how it is refreshed.
    public static func parseWebLogin(_ raw: String) -> XunleiCredential? {
        guard var parsed = parse(raw) else { return nil }
        parsed.authType = XunleiWebAuth.authType
        return parsed
    }

    /// Accepts a JSON object (snake_case or camelCase, optionally nested one or two levels under
    /// `credentials` / `token` / `data`), a JSON string holding such an object, or a bare access token
    /// with an optional `Bearer ` prefix. Any token with the wrong shape fails the whole parse, because the
    /// login page writes half-finished values into localStorage.
    public static func parse(_ raw: String) -> XunleiCredential? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        if text.hasPrefix("\""), let unwrapped = try? JSONSerialization.jsonObject(with: Data(text.utf8), options: .fragmentsAllowed) as? String {
            text = unwrapped.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if text.isEmpty { return nil }
        guard text.hasPrefix("{") else {
            var token = text
            if let bearer = token.range(of: #"^Bearer\s+"#, options: [.regularExpression, .caseInsensitive]) { token.removeSubrange(bearer) }
            token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            return isValidToken(token) ? XunleiCredential(accessToken: token) : nil
        }
        guard let root = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else { return nil }
        return fields(from: flatten(unwrap(root)))
    }

    /// 16 to 16384 JWT/Base64 characters, and not a placeholder such as "null".
    public static func isValidToken(_ value: String) -> Bool {
        value.count >= 16 && value.count <= 16_384 && value != "null" && value != "undefined"
            && value.range(of: #"^[A-Za-z0-9._~+/=-]+$"#, options: .regularExpression) != nil
    }

    private static func fields(from map: [String: String]) -> XunleiCredential? {
        let access = pick(map, "access_token", "accessToken")
        let refresh = pick(map, "refresh_token", "refreshToken")
        if !access.isEmpty, !isValidToken(access) { return nil }
        if !refresh.isEmpty, !isValidToken(refresh) { return nil }
        if access.isEmpty && refresh.isEmpty { return nil }
        let captcha = pick(map, "captcha_token", "captchaToken")
        return XunleiCredential(accessToken: access, refreshToken: refresh,
                                deviceId: pick(map, "device_id", "deviceId"),
                                captchaToken: isValidToken(captcha) ? captcha : "",
                                userId: pick(map, "user_id", "userId", "sub"),
                                nickname: pick(map, "nick_name", "nickname", "name", "user_name"),
                                authType: pick(map, "auth_type", "authType"))
    }

    private static func unwrap(_ root: [String: Any]) -> [String: Any] {
        var current = root
        for _ in 0..<2 {
            if ["access_token", "accessToken", "refresh_token", "refreshToken"].contains(where: { current[$0] != nil }) { return current }
            guard let nested = ["credentials", "token", "data"].lazy.compactMap({ current[$0] as? [String: Any] }).first else { return current }
            current = nested
        }
        return current
    }

    /// Strings and numbers only: a token is always a string.
    private static func flatten(_ object: [String: Any]) -> [String: String] {
        object.reduce(into: [:]) { result, entry in
            if let text = entry.value as? String { result[entry.key] = text }
            else if let number = entry.value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { result[entry.key] = number.stringValue }
        }
    }

    private static func pick(_ map: [String: String], _ keys: String...) -> String {
        for key in keys {
            let text = (map[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { continue }
            return text
        }
        return ""
    }

    // MARK: JWT

    /// `exp` in seconds, or 0 when the token is not a readable JWT.
    var tokenExpiry: Int64 { Self.payload(accessToken)?["exp"].flatMap { ($0 as? NSNumber)?.int64Value } ?? 0 }
    /// `sub`, the user id the captcha init asks for. Falls back to the stored `user_id`.
    var effectiveUserId: String { (Self.payload(accessToken)?["sub"] as? String)?.nonBlank ?? userId }

    static func payload(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count > 1 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
