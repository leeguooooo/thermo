import Foundation
import Security

/// Automatic work never presents Keychain UI. Only the page's explicit authorization action may ask.
final class YunXKeychainSession: @unchecked Sendable {
    static let shared = YunXKeychainSession(
        read: { try YunXKeychainBackend(account: $0).readItem(interactive: $1) },
        write: { try YunXKeychainBackend(account: $0).writeItem($1) }
    )

    private let lock = NSLock()
    private let readItem: (String, Bool) throws -> Data?
    private let writeItem: (String, Data) throws -> Void
    private var values: [String: Result<Data?, Error>] = [:]

    init(read: @escaping (String, Bool) throws -> Data?, write: @escaping (String, Data) throws -> Void) {
        readItem = read
        writeItem = write
    }

    var authorizationRequired: Bool {
        lock.withLock {
            values.values.contains { result in
                if case let .failure(error) = result { return Self.needsAuthorization(error) }
                return false
            }
        }
    }

    func read(_ account: String, interactive: Bool = false) throws -> Data? {
        try lock.withLock { try load(account, interactive: interactive) }
    }

    private func load(_ account: String, interactive: Bool) throws -> Data? {
        if let cached = values[account] {
            switch cached {
            case let .success(data): return data
            case let .failure(error):
                if !interactive { throw error }
            }
        }
        do {
            let data = try readItem(account, interactive)
            values[account] = .success(data)
            return data
        } catch {
            if Self.needsAuthorization(error) { values[account] = .failure(error) }
            throw error
        }
    }

    func write(_ data: Data, account: String) throws {
        try lock.withLock {
            // A denied read must never turn into an empty list overwriting saved accounts or jobs.
            _ = try load(account, interactive: false)
            do {
                try writeItem(account, data)
                values[account] = .success(data)
            } catch {
                if Self.needsAuthorization(error) { values[account] = .failure(error) }
                throw error
            }
        }
    }

    func authorize() throws {
        for account in ["vault", "downloads", "trackers"] {
            _ = try read(account, interactive: true)
        }
    }

    private static func needsAuthorization(_ error: Error) -> Bool {
        guard case let YunXKeychainError.status(status) = error else { return false }
        return [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(status)
    }
}
