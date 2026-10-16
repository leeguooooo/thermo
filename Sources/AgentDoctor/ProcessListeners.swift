import AgentCore
import Darwin
import Foundation

public struct ProcessListeners: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case observed, noneObserved, unavailable }
    public struct Endpoint: Codable, Sendable, Hashable {
        public enum AddressKind: String, Codable, Sendable { case loopback, wildcardAddress, specifiedAddress }
        public var address: String
        public var port: UInt16
        public var family: String
        public var addressKind: AddressKind
        public var label: String { family == "IPv6" && address != "*" ? "[\(address)]:\(port)" : "\(address):\(port)" }
    }
    public var state: State
    public var endpoints: [Endpoint]
    /// Tool-query completeness only, never a guarantee of full kernel visibility.
    public var queryComplete: Bool
    public var limited: Bool

    public static func capture(_ pid: Int32) -> ProcessListeners {
        guard pid > 0, let before = ProcessTable.identity(pid), before.uid == getuid() else { return unavailable }
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("LSOF") { environment.removeValue(forKey:key) }
        environment["LC_ALL"] = "C"
        let result = CommandRunner.run("/usr/sbin/lsof", arguments:["-nP", "-a", "-p", String(pid), "-iTCP", "-sTCP:LISTEN", "-F0pftPn"],
                                       environment:environment, timeout:3, outputLimit:131_072)
        guard ProcessTable.identity(pid) == before else { return unavailable }
        return parse(result, pid:pid)
    }

    static var unavailable: ProcessListeners { .init(state:.unavailable,endpoints:[],queryComplete:false,limited:false) }

    static func parse(_ result: CommandRunner.Result, pid: Int32, maximumEndpoints: Int = 64) -> ProcessListeners {
        guard pid > 0, maximumEndpoints > 0, maximumEndpoints <= 256 else { return unavailable }
        let finished = !result.timedOut && !result.cancelled && !result.truncated
        var clean = finished && result.status == 0
        var limited = result.truncated
        if result.output.isEmpty {
            return .init(state:finished && result.status == 1 ? .noneObserved : .unavailable,endpoints:[],queryComplete:finished && result.status == 1,limited:limited)
        }
        var fields = result.output.split(separator:"\0",omittingEmptySubsequences:false).map(String.init)
        if !result.output.hasSuffix("\0") && !result.output.hasSuffix("\0\n") {
            clean = false; fields.removeLast()
        }
        var associated = false, sawPID = false, file: String?, family: String?, proto: String?, name: String?
        var endpoints = Set<Endpoint>()
        func finish() {
            guard file != nil else { return }
            guard associated, let family, proto == "TCP", let name, let parsedEndpoint = Self.endpoint(name, family:family) else { clean = false; return }
            if endpoints.count < maximumEndpoints { endpoints.insert(parsedEndpoint) }
            else if !endpoints.contains(parsedEndpoint) { limited = true; clean = false }
        }
        for raw in fields {
            let field = raw.drop(while: { $0 == "\n" })
            guard let key = field.first else { continue }
            let value = String(field.dropFirst())
            switch key {
            case "p":
                finish();file=nil;family=nil;proto=nil;name=nil
                guard Int32(value) == pid else { return unavailable }
                associated=true;sawPID=true
            case "f":
                finish();family=nil;proto=nil;name=nil
                guard associated, !value.isEmpty, value.allSatisfy(\.isNumber) else { return unavailable }
                file=value
            case "t": family=value
            case "P": proto=value
            case "n": name=value
            default: clean=false
            }
        }
        finish()
        let found = endpoints.sorted { ($0.port,$0.family,$0.address) < ($1.port,$1.family,$1.address) }
        if !found.isEmpty { return .init(state:.observed,endpoints:found,queryComplete:clean && sawPID,limited:limited) }
        return .init(state:clean && sawPID ? .noneObserved : .unavailable,endpoints:[],queryComplete:clean && sawPID,limited:limited)
    }

    static func endpoint(_ value: String, family: String) -> Endpoint? {
        guard ["IPv4","IPv6"].contains(family), value.count <= 512, let separator=value.lastIndex(of:":"),
              value[value.index(after:separator)...].allSatisfy({ $0.isASCII && $0.isNumber }),
              let port=UInt16(value[value.index(after:separator)...]), port > 0 else { return nil }
        var address=String(value[..<separator])
        if address.hasPrefix("[") && address.hasSuffix("]") { address=String(address.dropFirst().dropLast()) }
        else if family == "IPv6" && address.contains(":") { return nil }
        if address == "*" { return .init(address:address,port:port,family:family,addressKind:.wildcardAddress) }
        if family == "IPv4" {
            var parsed=in_addr()
            guard address.withCString({ inet_pton(AF_INET,$0,&parsed) }) == 1 else { return nil }
            let kind: Endpoint.AddressKind = parsed.s_addr == 0 ? .wildcardAddress : UInt32(bigEndian:parsed.s_addr) >> 24 == 127 ? .loopback : .specifiedAddress
            return .init(address:address,port:port,family:family,addressKind:kind)
        }
        let parts=address.split(separator:"%",omittingEmptySubsequences:false)
        guard parts.count <= 2, let host=parts.first,
              parts.count == 1 || (!parts[1].isEmpty && parts[1].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_.-".contains($0)) })) else { return nil }
        var parsed=in6_addr()
        guard String(host).withCString({ inet_pton(AF_INET6,$0,&parsed) }) == 1 else { return nil }
        let bytes=withUnsafeBytes(of:parsed) { Array($0) }
        let kind: Endpoint.AddressKind = bytes.allSatisfy({ $0 == 0 }) ? .wildcardAddress : bytes.prefix(15).allSatisfy({ $0 == 0 }) && bytes[15] == 1 ? .loopback : .specifiedAddress
        return .init(address:address,port:port,family:family,addressKind:kind)
    }
}
