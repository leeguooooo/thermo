// The Kotlin source keeps these fields in GuangYaAccountEntity (Room). The protocol passes one opaque
// DriveCredential, so the fields travel inside it as JSON. A bare string is an access token.
import Foundation

/// Device identity made once per login and reused for every request, as GuangYaAccountRepository.deviceOf does.
public struct GuangYaDevice: Sendable, Equatable {
    public let deviceId: String
    public let deviceSign: String
    public init(deviceId: String, deviceSign: String) {
        self.deviceId = deviceId
        self.deviceSign = deviceSign
    }
    /// Fresh identity for a first login.
    public static func make() -> GuangYaDevice {
        let id = GuangYaConstants.newDeviceId()
        return GuangYaDevice(deviceId: id, deviceSign: GuangYaConstants.newDeviceSign(deviceId: id))
    }
}

public struct GuangYaTokens: Sendable, Equatable, CustomStringConvertible, CustomReflectable {
    public let accessToken: String
    public let refreshToken: String
    /// Seconds; 0 when the server did not say.
    public let expiresIn: Int64
    public var description: String { "GuangYaTokens(<redacted>)" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

public struct GuangYaAccountInfo: Sendable, Equatable {
    public let userId: String
    public let nickname: String
}

public struct GuangYaSmsChallenge: Sendable, Equatable {
    public let verificationId: String
    public let isUser: Bool
    public let expiresIn: Int
}

public struct GuangYaCredential: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var accessToken: String
    public var refreshToken: String
    public var device: GuangYaDevice?
    /// Milliseconds since 1970; 0 when unknown, which forces a refresh before first use as in the source.
    public var accessExpiresAt: Int64

    public init(accessToken: String, refreshToken: String = "", device: GuangYaDevice? = nil, accessExpiresAt: Int64 = 0) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.device = device
        self.accessExpiresAt = accessExpiresAt
    }

    public var description: String { "GuangYaCredential(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public init(_ credential: DriveCredential) {
        let text = credential.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("{"), let json = LenientJSON(data: Data(text.utf8)) else {
            self.init(accessToken: text)
            return
        }
        let id = json.string("deviceId"), sign = json.string("deviceSign")
        self.init(accessToken: json.string("accessToken"), refreshToken: json.string("refreshToken"),
                  device: id.isBlankText ? nil : GuangYaDevice(deviceId: id, deviceSign: sign),
                  accessExpiresAt: json.int64("accessExpiresAt"))
    }

    public var driveCredential: DriveCredential {
        var object: [String: Any] = ["accessToken": accessToken, "refreshToken": refreshToken, "accessExpiresAt": accessExpiresAt]
        if let device {
            object["deviceId"] = device.deviceId
            object["deviceSign"] = device.deviceSign
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return DriveCredential(String(decoding: data, as: UTF8.self))
    }
}
