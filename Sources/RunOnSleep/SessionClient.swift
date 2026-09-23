import Foundation
import Darwin
import RunOnSleepCore

/// Used only on AppModel's worker queue. Tokens never leave this object.
final class SessionClient: @unchecked Sendable {
    private let backend = MacPowerBackend()
    private lazy var local = SessionEngine(backend: backend, authorizedUID: getuid(), permitsGlobalWrites: false)
    private let peer = Peer(uid: getuid(), identity: Data(UUID().uuidString.utf8))
    private var token: String?
    private var sequence: UInt64 = 0
    private var localSession = false
    private var lastRenew: TimeInterval = 0
    private var helperInstance: String?

    struct Update {
        var status: Status
        var helperAvailable: Bool
        var error: String?
    }

    private func perform(_ request: Request) throws -> Response {
        if localSession { return local.handle(request, peer: peer) }
        return try UnixTransport.call(request)
    }

    func poll() throws -> Update {
        if token != nil {
            var request = Request(.status)
            if backend.now - lastRenew >= 10 {
                sequence += 1
                request = Request(.renew, token: token, sequence: sequence)
            }
            let response = try perform(request)
            if request.operation == .renew && response.ok { lastRenew = backend.now }
            let wasLocal = localSession
            if !response.status.active || (!wasLocal && helperInstance != response.status.instanceID) {
                token = nil; localSession = false
            }
            return Update(status: response.status, helperAvailable: !wasLocal, error: response.error)
        }
        do {
            let response = try UnixTransport.call(Request(.status))
            return Update(status: response.status, helperAvailable: true, error: response.error)
        } catch {
            return Update(status: local.status(), helperAvailable: false, error: nil)
        }
    }

    func start(_ options: SessionOptions) throws -> Update {
        guard token == nil else { throw ServiceError.failure("This app already has an active session.") }
        // Discover transport before start. Never retry a possibly successful start over another transport.
        do {
            let response = try UnixTransport.call(Request(.status))
            guard response.ok else { throw ServiceError.failure(response.error ?? "Helper unavailable.") }
            localSession = false
        } catch {
            guard !options.closedLid else { throw error }
            localSession = true
        }
        let response = try perform(Request(.start, options: options))
        guard response.ok, let newToken = response.token else {
            localSession = false
            throw ServiceError.failure(response.error ?? "Could not start a session.")
        }
        token = newToken; sequence = 0; lastRenew = backend.now; helperInstance = response.status.instanceID
        return Update(status: response.status, helperAvailable: !localSession, error: nil)
    }

    func stop() throws -> Update {
        guard let token else {
            let update = try poll()
            if update.status.active {
                throw ServiceError.failure("This session belongs to another app process. Stop it there, or wait for its lease to expire after that process quits.")
            }
            return update
        }
        sequence += 1
        let response = try perform(Request(.stop, token: token, sequence: sequence))
        let wasLocal = localSession
        self.token = nil; localSession = false
        return Update(status: response.status, helperAvailable: !wasLocal, error: response.error)
    }

    func localSafetyTick() { if localSession { local.tick() } }
}
