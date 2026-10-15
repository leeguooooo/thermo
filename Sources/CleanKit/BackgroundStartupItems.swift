import AgentCore
import Foundation
import Darwin

public struct BackgroundStartupItem: Codable, Sendable, Equatable, Identifiable {
    public var id: String { "\(uid):\(uuid)" }
    public var uid: Int
    public var uuid: String
    public var name: String
    public var identifier: String?
    public var kind: String?
    public var path: String?
    public var executable: String?
    public var disposition: [String]
    public var requested: Bool?
    public var allowed: Bool?
}

public struct BackgroundStartupReport: Codable, Sendable {
    public enum Status: String, Codable, Sendable { case requiresAuthorization, available, partial, unavailable }
    public var status: Status
    public var items: [BackgroundStartupItem]
    public var issues: [String]
    public var observedAt: Date?
    public static var requiresAuthorization: Self { .init(status: .requiresAuthorization, items: [], issues: [], observedAt: nil) }
}

/// BTM diagnostic output is a human-readable, version-dependent format. Unknown
/// structure is not an empty inventory and raw output never becomes a launchctl selector.
public enum BackgroundStartupItems {
    public static func parse(_ result: CommandRunner.Result, uid: Int = Int(getuid())) -> BackgroundStartupReport {
        guard result.status == 0, !result.timedOut, !result.cancelled, !result.truncated else {
            return .init(status: .unavailable, items: [], issues: [result.timedOut ? "Background item reading timed out" : result.cancelled ? "Background item reading cancelled" : result.truncated ? "Background item output was incomplete" : "Background item reading failed"], observedAt: nil)
        }
        var currentUID: Int?, recordUID: Int?, fields: [String: String] = [:]
        var seenGroup = false, seenItems = false, recordStarted = false, invalidRecord = false
        var items: [BackgroundStartupItem] = [], issues: [String] = []
        func value(_ key: String) -> String? {
            guard let text = fields[key], !text.isEmpty, text != "(null)", text != "null" else { return nil }; return text
        }
        func flush() {
            guard recordStarted else { return }
            defer { fields = [:]; recordStarted = false; invalidRecord = false }
            guard let user = recordUID else { issues.append("Background item user scope could not be verified"); return }
            guard user == uid || user == 0 else { return }
            guard !invalidRecord, let uuid = value("UUID"), UUID(uuidString: uuid) != nil, let name = value("Name"), name.utf8.count <= 4096 else {
                issues.append("A background item record could not be verified"); return
            }
            var tokens: [String] = []
            if let raw = value("Disposition"), let start = raw.firstIndex(of: "["), let end = raw[start...].firstIndex(of: "]") {
                tokens = raw[raw.index(after: start)..<end].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
            func flag(_ yes: String, _ no: String) -> Bool? {
                let positive = tokens.contains(yes), negative = tokens.contains(no)
                return positive == negative ? nil : positive
            }
            let requested = flag("enabled", "disabled"), allowed = flag("allowed", "disallowed")
            if requested == nil || allowed == nil { issues.append("A background item's registration or approval state is unknown") }
            let path = value("URL").flatMap { text -> String? in
                guard let url = URL(string: text), url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else { return nil }
                return url.path
            }
            items.append(.init(uid: user, uuid: uuid.lowercased(), name: name, identifier: value("Identifier"), kind: value("Type"), path: path,
                               executable: value("Executable Path"), disposition: tokens, requested: requested, allowed: allowed))
        }
        for raw in result.output.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("Records for UID ") {
                flush(); seenGroup = true
                let suffix = line.dropFirst("Records for UID ".count)
                currentUID = Int(suffix.split(separator: ":", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? "")
                if currentUID == nil { issues.append("Background item user scope could not be verified") }
            } else if line == "Items:" || line.hasPrefix("Items: ") {
                if currentUID == uid || currentUID == 0 { seenItems = true }
            } else if line.range(of: #"^#[0-9]+:$"#, options: .regularExpression) != nil {
                flush(); recordStarted = true; recordUID = currentUID
            } else if recordStarted, let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon]), text = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                if ["UUID", "Name", "Identifier", "Type", "URL", "Executable Path", "Disposition"].contains(key) {
                    if fields[key] != nil { issues.append("A background item contains duplicate fields"); invalidRecord = true }
                    if text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) { invalidRecord = true }
                    fields[key] = text
                }
            } else if !recordStarted, ["UUID:", "Name:", "Disposition:"].contains(where: line.hasPrefix) {
                issues.append("A background item boundary could not be verified")
            }
        }
        flush()
        guard seenGroup && seenItems else { return .init(status: .unavailable, items: [], issues: ["Background item output format was not recognized"], observedAt: nil) }
        let duplicates = Set(Dictionary(grouping: items, by: \.id).filter { $0.value.count > 1 }.keys)
        if !duplicates.isEmpty { issues.append("Duplicate background item identities require review"); items.removeAll { duplicates.contains($0.id) } }
        return .init(status: issues.isEmpty ? .available : .partial, items: items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, issues: Array(Set(issues)).sorted(), observedAt: Date())
    }
}
