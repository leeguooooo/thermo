import Foundation
import Security
import Darwin

/// Preserve the helper's signed-client boundary when the App brokers a user-level request.
/// Production accepts our CLI identity from our own Developer ID team. Development pins the
/// companion CLI's designated requirement once at listener startup; it never falls back to UID alone.
public final class LocalControlPeerTrust: @unchecked Sendable {
    private let requirement: SecRequirement
    public enum Role: String, Sendable { case cli = "dev.thermo.cli", app = "dev.thermo.app" }
    public init(team: String?, developmentExecutable: URL, role: Role = .cli) throws {
        var requirement: SecRequirement?
        if let team {
            guard team.range(of:"^[A-Z0-9]{10}$",options:.regularExpression) != nil else { throw TrustError() }
            let expression = #"anchor apple generic and identifier ""# + role.rawValue + #"" and certificate leaf[subject.OU] = ""# + team + #"""#
            guard SecRequirementCreateWithString(expression as CFString,[],&requirement) == errSecSuccess else { throw TrustError() }
        } else {
            var code: SecStaticCode?
            guard SecStaticCodeCreateWithPath(developmentExecutable as CFURL,[],&code) == errSecSuccess, let code,
                  SecStaticCodeCheckValidity(code,[],nil) == errSecSuccess,
                  SecCodeCopyDesignatedRequirement(code,[],&requirement) == errSecSuccess else { throw TrustError() }
        }
        guard let requirement else { throw TrustError() }
        self.requirement = requirement
    }
    public func accepts(auditToken: Data) -> Bool {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return false }
        var guest: SecCode?
        let attributes = [kSecGuestAttributeAudit as String:auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil,attributes,[],&guest) == errSecSuccess, let guest else { return false }
        return SecCodeCheckValidity(guest,[],requirement) == errSecSuccess
    }
    struct TrustError: LocalizedError {
        var errorDescription: String? { "Cannot establish the companion CLI signing requirement. App control is unavailable; no requests were accepted." }
    }
}
