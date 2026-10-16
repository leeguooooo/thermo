import AgentCore
import Darwin
import Foundation

public struct ProcessLaunchServices: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case observed, noneObserved, unavailable }
    public struct Registration: Codable, Sendable, Hashable {
        public var domain: String
        public var label: String
        public var pid: Int32
        public var serviceState: String?
    }
    public var state: State
    public var registrations: [Registration]
    public var queriedDomains: [String]
    public var queryComplete: Bool

    public static func capture(_ pid: Int32) -> ProcessLaunchServices {
        let started = DispatchTime.now().uptimeNanoseconds
        return capture(pid, uid:getuid(), identity:ProcessTable.identity, run:{ arguments in
            var environment=ProcessInfo.processInfo.environment;environment["LC_ALL"]="C"
            // An exhausted overall budget gives CommandRunner a zero timeout: it refuses
            // to launch another child, and the result remains incomplete.
            let remaining = max(0, 6 - Double(DispatchTime.now().uptimeNanoseconds - started) / 1e9)
            return CommandRunner.run("/bin/launchctl",arguments:arguments,environment:environment,timeout:min(3, remaining),outputLimit:2_097_152,captureError:false)
        })
    }

    static var unavailable: ProcessLaunchServices { .init(state:.unavailable,registrations:[],queriedDomains:[],queryComplete:false) }
    static func finished(_ result: CommandRunner.Result) -> Bool { result.status == 0 && !result.timedOut && !result.cancelled && !result.truncated }
    static func labelIsSafe(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 1024 && value != "." && value != ".." && !value.contains("/") &&
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func labels(_ text: String, domain: String, pid: Int32) -> [String]? {
        let lines=text.split(separator:"\n",omittingEmptySubsequences:false)
        guard lines.first.map({ $0.trimmingCharacters(in:.whitespaces)==domain+" = {" }) == true else { return nil }
        var inside=false, ended=false, seen=false, count=0, labels: [String]=[]
        for raw in lines.dropFirst() {
            if raw == "\tservices = {" {
                guard !seen else { return nil };seen=true;inside=true;continue
            }
            guard inside else { continue }
            if raw == "\t}" { inside=false;ended=true;continue }
            if raw.trimmingCharacters(in:.whitespaces).isEmpty { continue }
            guard raw.hasPrefix("\t\t"), !raw.hasPrefix("\t\t\t"), count < 20_000 else { return nil }
            count+=1
            let fields=raw.trimmingCharacters(in:.whitespaces).split(whereSeparator:{ $0==" " || $0=="\t" })
            guard fields.count==3 else { return nil }
            if fields[0]=="-" { continue }
            guard let owner=Int32(fields[0]),owner>=0 else { return nil }
            if owner==pid {
                let label=String(fields[2]);guard labelIsSafe(label), labels.count < 16 else { return nil }
                labels.append(label)
            }
        }
        guard seen, ended, !inside else { return nil }
        return Array(Set(labels)).sorted()
    }

    static func capture(_ pid: Int32, uid: UInt32, identity:(Int32)->ProcessIdentity?, run:([String])->CommandRunner.Result) -> ProcessLaunchServices {
        guard pid>0,let before=identity(pid),before.pid==pid,before.uid==uid else { return unavailable }
        let domains=["gui/\(uid)","user/\(uid)"]
        var complete=true,queried:[String]=[],found=Set<Registration>()
        for domain in domains {
            let snapshot=run(["print",domain]);queried.append(domain)
            guard finished(snapshot), let candidates=labels(snapshot.output,domain:domain,pid:pid) else { complete=false;continue }
            for label in candidates {
                let target=domain+"/"+label,result=run(["print",domain+"/"+label])
                let lines = result.output.split(separator:"\n")
                guard finished(result), lines.first.map({ $0.trimmingCharacters(in:.whitespaces)==target+" = {" }) == true,
                      lines.last == "}", lines.filter({ $0.hasPrefix("\tpid = ") }).count == 1 else { complete=false;continue }
                let state=Launchd.state(result.output)
                guard state.pid==pid else { complete=false;continue }
                found.insert(.init(domain:domain,label:ProcessExplanation.displayed(label),pid:pid,serviceState:state.state.map(ProcessExplanation.displayed)))
            }
        }
        guard identity(pid)==before else { return unavailable }
        let matches=found.sorted { ($0.domain,$0.label)<($1.domain,$1.label) }
        return .init(state:matches.isEmpty ? complete ? .noneObserved : .unavailable : .observed,
                     registrations:matches,queriedDomains:queried,queryComplete:complete)
    }
}
