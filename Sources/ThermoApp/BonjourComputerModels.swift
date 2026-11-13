import Darwin
import Foundation
import dnssd

/// A name-matched LAN hint for display, not a Bluetooth identity or a grant to connect.
enum BonjourComputerModels {
    struct Answer: Sendable, Equatable {
        var model: String?
        var accessBlocked = false
    }
    struct Batch: Sendable {
        var models: [String: String] = [:]
        var accessBlocked = false
    }
    static let limit = 32

    static func nameKey(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
    }

    static func isMac(_ model: String) -> Bool {
        model.range(of: #"\A(?:Mac(?:Book(?:Air|Pro)?|mini|Pro|Studio)?|iMac(?:Pro)?|Xserve)[0-9]+,[0-9]+\z"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// TXT values are length-prefixed binary strings, not a printable command-line dump.
    static func model(in data: Data) -> String? {
        guard data.count <= 4096 else { return nil }
        let bytes = Array(data)
        var offset = 0, models = Set<String>()
        while offset < bytes.count {
            let length = Int(bytes[offset]); offset += 1
            guard offset + length <= bytes.count else { return nil }
            let field = bytes[offset..<offset + length]; offset += length
            guard let equals = field.firstIndex(of: 61),
                  let key = String(bytes: field[..<equals], encoding: .ascii), key.lowercased() == "model" else { continue }
            let value = field[field.index(after: equals)...]
            guard !value.isEmpty, value.count <= 128, let model = String(bytes: value, encoding: .utf8) else { return nil }
            models.insert(model)
        }
        return models.count == 1 ? models.first : nil
    }

    static func lookup(_ names: [String], resolve: @escaping @Sendable (String) async -> Answer = { await query($0) }) async -> Batch {
        guard !Task.isCancelled else { return Batch() }
        var seen = Set<String>()
        var iterator = names.filter { !$0.isEmpty && $0.utf8.count <= 63 && !$0.utf8.contains(0) && seen.insert(nameKey($0)).inserted }
            .prefix(limit).makeIterator()
        return await withTaskGroup(of: (String, Answer).self) { group in
            var result = Batch()
            for _ in 0..<4 {
                if let name = iterator.next() { group.addTask { (nameKey(name), await resolve(name)) } }
            }
            while let (key, answer) = await group.next() {
                if Task.isCancelled { group.cancelAll(); return Batch() }
                if answer.accessBlocked { result.accessBlocked = true; result.models.removeAll(); group.cancelAll(); break }
                if let model = answer.model, isMac(model) { result.models[key] = model }
                if let name = iterator.next() { group.addTask { (nameKey(name), await resolve(name)) } }
            }
            return result
        }
    }

    static func query(_ name: String) async -> Answer {
        guard !Task.isCancelled else { return Answer() }
        let job = Task.detached(priority: .utility) { blockingQuery(name) }
        return await withTaskCancellationHandler(operation: { await job.value }, onCancel: { job.cancel() })
    }

    private final class Reply {
        var models: [UInt32: Set<String>] = [:]
        var invalid = false
        var failed = false
        var blocked = false
        var updated: Double?
        func receive(flags: DNSServiceFlags, interface: UInt32, error: DNSServiceErrorType, type: UInt16,
                     length: UInt16, bytes: UnsafeRawPointer?) {
            guard error == kDNSServiceErr_NoError else {
                failed = true; blocked = error == kDNSServiceErr_PolicyDenied; return
            }
            guard type == kDNSServiceType_TXT, length <= 4096, let bytes else { invalid = true; return }
            updated = ProcessInfo.processInfo.systemUptime
            guard let model = BonjourComputerModels.model(in: Data(bytes: bytes, count: Int(length))) else { invalid = true; return }
            if flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0 { models[interface, default: []].insert(model) }
            else { models[interface]?.remove(model) }
        }
        var answer: Answer {
            let values = Set(models.values.flatMap { $0 })
            return Answer(model: !invalid && !failed && values.count == 1 ? values.first : nil, accessBlocked: blocked)
        }
    }

    private static func blockingQuery(_ name: String) -> Answer {
        guard !Task.isCancelled, !name.isEmpty, name.utf8.count <= 63, !name.utf8.contains(0) else { return Answer() }
        var fullName = [CChar](repeating: 0, count: Int(kDNSServiceMaxDomainName))
        // Construct a literal service-instance label; dots and escapes in a device name cannot change the domain/type.
        guard DNSServiceConstructFullName(&fullName, name, "_device-info._tcp", "local.") == 0 else { return Answer() }
        let reply = Reply()
        return withExtendedLifetime(reply) {
            var service: DNSServiceRef?
            let error = DNSServiceQueryRecord(&service, 0, UInt32(kDNSServiceInterfaceIndexAny), fullName,
                UInt16(kDNSServiceType_TXT), UInt16(kDNSServiceClass_IN), { _, flags, interface, error, _, type, _, length, bytes, _, context in
                    guard let context else { return }
                    Unmanaged<Reply>.fromOpaque(context).takeUnretainedValue()
                        .receive(flags: flags, interface: interface, error: error, type: type, length: length, bytes: bytes)
                }, Unmanaged.passUnretained(reply).toOpaque())
            guard error == kDNSServiceErr_NoError, let service else { return Answer(accessBlocked: error == kDNSServiceErr_PolicyDenied) }
            defer { DNSServiceRefDeallocate(service) }
            let fd = DNSServiceRefSockFD(service)
            guard fd >= 0 else { return Answer() }
            let deadline = ProcessInfo.processInfo.systemUptime + 1.2
            while !Task.isCancelled && !reply.failed && ProcessInfo.processInfo.systemUptime < deadline {
                if let updated = reply.updated, ProcessInfo.processInfo.systemUptime - updated >= 0.15 { break }
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&descriptor, 1, 50)
                if ready < 0 { if errno == EINTR { continue }; return Answer() }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return Answer() }
                if ready > 0, DNSServiceProcessResult(service) != kDNSServiceErr_NoError { return Answer() }
            }
            return Task.isCancelled ? Answer() : reply.answer
        }
    }
}
