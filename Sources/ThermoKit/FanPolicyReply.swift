import Foundation

/// Preserve the existing policy-dictionary reply on success. The reserved error envelope
/// makes old clients fail decoding too, rather than interpreting unknown hardware as auto.
public enum FanPolicyReply {
    private struct Failure: Codable { var _thermoError: String }

    public static func encode(_ policies: [Int: FanPolicy], recovery: FanAutoRecoveryReport?, controlError: String? = nil) throws -> Data {
        if let recovery, !recovery.confirmed { return try PolicyCoding.encoder().encode(Failure(_thermoError: recovery.summary)) }
        if let controlError { return try PolicyCoding.encoder().encode(Failure(_thermoError: controlError)) }
        return try PolicyCoding.encoder().encode(policies)
    }

    public static func decode(_ data: Data) throws -> [Int: FanPolicy] {
        if let failure = try? PolicyCoding.decoder().decode(Failure.self, from: data) { throw FanControlError.helper(failure._thermoError) }
        return try PolicyCoding.decoder().decode([Int: FanPolicy].self, from: data)
    }
}
