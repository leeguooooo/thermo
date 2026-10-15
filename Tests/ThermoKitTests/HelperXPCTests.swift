import Foundation
import XCTest
@testable import ThermoKit

/// Real Foundation XPC transport, with an owned endpoint and no privileged service or hardware.
final class HelperXPCTests: XCTestCase {
    final class Service: NSObject, ThermoHelperProtocol, @unchecked Sendable {
        struct State {
            var version = "5/fixture"
            var control = FanControlState(policies: [:])
            var policyData: Data?
            var controlData: Data?
            var preparationError: String?
            var preparations: [(Bool, String)] = []
            var controlCalls = 0
            var holdVersion = false
            var heldReplies: [(String) -> Void] = []
        }
        private var state = State()
        private let lock = NSLock()
        func access<T>(_ body: (inout State) -> T) -> T {
            lock.lock(); defer { lock.unlock() }; return body(&state)
        }
        func version(reply: @escaping (String) -> Void) {
            let value: String? = access {
                if $0.holdVersion { $0.heldReplies.append(reply); return nil }
                return $0.version
            }
            if let value { reply(value) }
        }
        func setPolicy(fan: Int, policy: Data, reply: @escaping (String?) -> Void) {
            do {
                let decoded = try PolicyCoding.decoder().decode(FanPolicy.self, from: policy)
                try decoded.validate()
                access {
                    $0.control.policies[fan] = decoded == .auto ? nil : decoded
                    $0.control.observations[fan] = nil
                }
                reply(nil)
            } catch { reply(String(describing: error)) }
        }
        func policies(reply: @escaping (Data) -> Void) {
            let data = access { state in
                state.policyData ?? (try! FanPolicyReply.encode(state.control.policies, recovery: nil, controlError: state.control.legacyError))
            }
            reply(data)
        }
        func fanControlState(reply: @escaping (Data) -> Void) {
            let data = access { state in
                state.controlCalls += 1
                return state.controlData ?? (try! PolicyCoding.encoder().encode(state.control))
            }
            reply(data)
        }
        func prepareRemoval(_ prepare: Bool, token: String, reply: @escaping (String?) -> Void) {
            let failure = access { $0.preparations.append((prepare, token)); return $0.preparationError }
            reply(failure)
        }
        func setLidAwake(_ on: Bool, reply: @escaping (String?) -> Void) { reply(nil) }
        func setLidAwake(_ on: Bool, heatGuard: Bool, reply: @escaping (String?) -> Void) { reply(nil) }
        func lidAwakeState(reply: @escaping (Data) -> Void) { reply(try! PolicyCoding.encoder().encode(LidAwakeState(limit: 95))) }
    }

    final class Endpoint: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let service = Service()
        private let lock = NSLock()
        private var connections: [NSXPCConnection] = []
        private var creations = 0
        override init() { super.init(); listener.delegate = self; listener.resume() }
        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: ThermoHelperProtocol.self)
            connection.exportedObject = service
            lock.lock(); connections.append(connection); lock.unlock()
            connection.resume(); return true
        }
        func client() -> HelperClient {
            HelperClient(makeConnection: {
                self.lock.lock(); self.creations += 1; self.lock.unlock()
                return NSXPCConnection(listenerEndpoint: self.listener.endpoint)
            })
        }
        var connectionCount: Int { lock.lock(); defer { lock.unlock() }; return creations }
        func disconnect() {
            lock.lock(); let active = connections; connections.removeAll(); lock.unlock()
            active.forEach { $0.invalidate() }
        }
        func stop() { disconnect(); listener.invalidate() }
    }

    func testAcceptedRequestIsPendingUntilAnIndependentObservedReplyArrives() async throws {
        let endpoint = Endpoint(); defer { endpoint.stop() }
        let client = endpoint.client(); defer { client.reset() }
        try await client.setPolicy(.fixed(rpm: .infinity), fan: 0)
        let pending = try await client.fanControlState()
        XCTAssertEqual(pending.policies[0], .fixed(rpm: .infinity))
        XCTAssertEqual(pending.verification(for: 0), .pending)
        do { _ = try await client.policies(); XCTFail("legacy active-policy reply must reject pending hardware state") }
        catch { XCTAssertTrue(String(describing: error).contains("has not been confirmed")) }
        endpoint.service.access { $0.control.observations[0] = .init(mode: .manual, target: 6000, checkedAt: Date(timeIntervalSince1970: 1000)) }
        let verified = try await client.fanControlState()
        XCTAssertEqual(verified.verification(for: 0), .checked)
        XCTAssertEqual(verified.observations[0]?.checkedAt, Date(timeIntervalSince1970: 1000))
        let active = try await client.policies()
        XCTAssertEqual(active[0], .fixed(rpm: .infinity))
    }

    func testLegacyVersionUsesDictionaryAndDoesNotInventHardwareObservations() async throws {
        let endpoint = Endpoint(); defer { endpoint.stop() }
        let legacy = try PolicyCoding.encoder().encode([0: FanPolicy.curve(.quiet)])
        endpoint.service.access { $0.version = "3/fixture"; $0.policyData = legacy }
        let client = endpoint.client(); defer { client.reset() }
        let state = try await client.fanControlState()
        XCTAssertEqual(state.policies[0], .curve(.quiet))
        XCTAssertFalse(state.observationsSupported)
        XCTAssertEqual(state.verification(for: 0), .unavailable)
        XCTAssertEqual(endpoint.service.access { $0.controlCalls }, 0)
    }

    func testMalformedStateReplyThrowsInsteadOfBecomingEmptyAutomaticPolicies() async throws {
        let endpoint = Endpoint(); defer { endpoint.stop() }
        endpoint.service.access { $0.controlData = Data("not JSON".utf8) }
        let client = endpoint.client(); defer { client.reset() }
        do { _ = try await client.fanControlState(); XCTFail("malformed state must fail") } catch { XCTAssertTrue(error is DecodingError) }
    }

    func testSemanticallyInvalidPoliciesAreRejectedInModernAndLegacyReplies() async throws {
        let endpoint = Endpoint(); defer { endpoint.stop() }
        let client = endpoint.client(); defer { client.reset() }
        for version in ["5/fixture", "3/fixture"] {
            for policies: [Int: FanPolicy] in [[0: .fixed(rpm: .nan)], [-1: .fixed(rpm: 2000)]] {
                let raw = try PolicyCoding.encoder().encode(policies)
                endpoint.service.access { $0.version = version; $0.control.policies = policies; $0.policyData = raw }
                do { _ = try await client.fanControlState(); XCTFail("invalid desired policies must not reach controls") }
                catch { XCTAssertTrue(error is FanControlError) }
            }
        }
    }

    func testRemovalBridgeSendsOneTokenAndCancelsAfterFailure() async throws {
        let endpoint = Endpoint(); defer { endpoint.stop() }
        let client = endpoint.client(); defer { client.reset() }
        let failure: Error? = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                do {
                    try client.withRemovalPreparation { throw FanControlError.helper("fixture authorization cancelled") }
                    continuation.resume(returning: nil)
                } catch { continuation.resume(returning: error) }
            }
        }
        XCTAssertTrue(String(describing: failure).contains("fixture authorization cancelled"))
        let calls = endpoint.service.access { $0.preparations }
        XCTAssertEqual(calls.map(\.0), [true, false])
        XCTAssertEqual(calls.first?.1, calls.last?.1)
        XCTAssertFalse(calls.first?.1.isEmpty ?? true)
        endpoint.service.access { $0.preparationError = "fixture automatic recovery unconfirmed" }
        do { try await client.prepareRemoval(true, token: "fault"); XCTFail("remote rejection must propagate") }
        catch { XCTAssertTrue(String(describing: error).contains("recovery unconfirmed")) }
    }

    func testLegacyVersionCannotEnterRemovalPreparation() async throws {
        let endpoint = Endpoint(); defer { endpoint.stop() }
        endpoint.service.access { $0.version = "3/fixture" }
        let client = endpoint.client(); defer { client.reset() }
        do { try await client.prepareRemoval(true, token: "legacy"); XCTFail("old helper must be refused") }
        catch { XCTAssertTrue(String(describing: error).contains("update the helper first")) }
        XCTAssertTrue(endpoint.service.access { $0.preparations.isEmpty })
    }

    func testServerDisconnectDropsTheConnectionAndAllowsReconnect() async throws {
        let endpoint = Endpoint(); defer { endpoint.stop() }
        let client = endpoint.client(); defer { client.reset() }
        let first = try await client.version(); XCTAssertEqual(first, "5/fixture")
        endpoint.disconnect()
        endpoint.service.access { $0.version = "5/reconnected" }
        var result: String?
        for _ in 0..<20 {
            if let version = try? await client.version(), endpoint.connectionCount >= 2 {
                result = version; break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(result, "5/reconnected")
        XCTAssertGreaterThanOrEqual(endpoint.connectionCount, 2)
    }

    func testMissingReplyTimesOutAndLateReplyCannotCorruptTheNextConnection() async throws {
        let endpoint = Endpoint(); defer { endpoint.stop() }
        endpoint.service.access { $0.holdVersion = true }
        let client = endpoint.client(); defer { client.reset() }
        do { _ = try await client.version(); XCTFail("missing reply must not hang") }
        catch { XCTAssertTrue(String(describing: error).contains("no answer within 3 s")) }
        let held = endpoint.service.access { state in
            state.holdVersion = false
            let held = state.heldReplies; state.heldReplies.removeAll(); return held
        }
        XCTAssertEqual(held.count, 1)
        let next = try await client.version(); XCTAssertEqual(next, "5/fixture")
        XCTAssertGreaterThanOrEqual(endpoint.connectionCount, 2)
        let freshConnectionCount = endpoint.connectionCount
        held.forEach { $0("5/late") }
        let stillFresh = try await client.version(); XCTAssertEqual(stillFresh, "5/fixture")
        XCTAssertEqual(endpoint.connectionCount, freshConnectionCount, "a late reply must not invalidate the replacement connection")
    }
}
