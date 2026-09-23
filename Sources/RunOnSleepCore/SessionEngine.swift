import Foundation

/// All calls must be serialized by the host. Owns sessions, never owns the global setting.
public final class SessionEngine {
    private struct Session {
        var peer: Peer
        var token: String
        var options: SessionOptions
        var started: TimeInterval
        var leaseEnd: TimeInterval
        var deadline: TimeInterval?
        var sequence: UInt64 = 0
        var borrowed: Bool
    }
    private let backend: PowerBackend
    private let authorizedUID: UInt32
    private let permitsGlobalWrites: Bool
    private var session: Session?
    private var journal: Journal?
    private var unresolved = false
    private var message = "Inactive."
    public let instanceID = UUID().uuidString

    public init(backend: PowerBackend, authorizedUID: UInt32, permitsGlobalWrites: Bool = true) {
        self.backend = backend; self.authorizedUID = authorizedUID; self.permitsGlobalWrites = permitsGlobalWrites
    }

    public func recover() {
        guard permitsGlobalWrites else { return }
        do {
            journal = try backend.readJournal()
            if journal != nil { cleanup() }
        } catch {
            unresolved = true; message = "Recovery journal cannot be read. Global state is unresolved."
        }
    }

    public func handle(_ request: Request, peer: Peer) -> Response {
        // An expired token never revives a session, even if its renewal arrives before the timer tick.
        tick()
        do {
            guard request.version == BuildInfo.protocolVersion else { throw failure("Protocol version mismatch. Reinstall the matching helper.") }
            guard peer.uid == authorizedUID else { throw failure("Unauthorized user.") }
            switch request.operation {
            case .start:
                guard request.token == nil, request.sequence == nil, let options = request.options, options.isValid else {
                    throw failure("Invalid session options.")
                }
                let token = try start(options, peer: peer)
                return Response(ok: true, token: token, status: status())
            case .renew, .stop:
                guard request.options == nil, let current = session, current.peer == peer,
                      let token = request.token, token == current.token,
                      let sequence = request.sequence, sequence > current.sequence else {
                    throw failure("Session token, client identity, or sequence is invalid or expired.")
                }
                if request.operation == .stop { end("Session stopped.") }
                else { session?.sequence = sequence; session?.leaseEnd = backend.now + 45 }
            case .status:
                guard request.token == nil, request.options == nil, request.sequence == nil else {
                    throw failure("Status does not accept session credentials.")
                }
            }
            return Response(ok: true, status: status())
        } catch { return Response(ok: false, error: error.localizedDescription, status: status()) }
    }

    public func status() -> Status {
        let env = backend.environment()
        var detail = message
        if let s = session {
            detail = s.borrowed ? "Sleep already disabled outside this session." : "Session active."
            if s.options.mode == .computerUse && env.lidClosed == true {
                detail = "Computer use interrupted: open the lid and unlock the desktop."
            } else if env.thermal == .serious { detail += " Thermal state is serious; reduce workload." }
            if env.onBattery, let charge = env.batteryPercent, charge <= max(20, s.options.batteryFloor + 5) {
                detail += " Low battery: protection ends at \(s.options.batteryFloor)%."
            }
        }
        if unresolved && session != nil { detail += " Global sleep state remains unresolved." }
        return Status(active: session != nil, options: session?.options,
                      elapsedSeconds: session.map { max(0, Int(backend.now - $0.started)) } ?? 0,
                      remainingSeconds: session?.deadline.map { max(0, Int($0 - backend.now)) },
                      environment: env, message: detail, unresolved: unresolved,
                      borrowedGlobalSetting: session?.borrowed ?? false, instanceID: instanceID)
    }

    public func tick() {
        guard let s = session else { return }
        let env = backend.environment()
        if backend.now >= s.leaseEnd { end("Client lease expired; session ended."); return }
        if let deadline = s.deadline, backend.now >= deadline { end("Session timer ended."); return }
        if env.consoleUID != authorizedUID { end("Console user changed or logged out; session ended."); return }
        if let reason = safetyReason(env, options: s.options) { end(reason); return }
        if s.options.closedLid {
            guard let observed = env.sleepDisabled else {
                markConflict("Cannot read the global setting; session ended with unresolved state."); return
            }
            if !observed { markConflict("External sleep-setting change detected; session ended without reversing it.") }
        }
    }

    public func shutdown() { end("Service stopped.") }

    private func start(_ options: SessionOptions, peer: Peer) throws -> String {
        guard session == nil else { throw failure("A session is already active.") }
        let env = backend.environment()
        guard env.consoleUID == authorizedUID else { throw failure("Start from the installing user's active desktop.") }
        if let reason = safetyReason(env, options: options) { throw failure(reason) }
        if options.mode == .computerUse && env.lidClosed != false { throw failure("Open the lid before starting computer use.") }
        if options.closedLid {
            guard permitsGlobalWrites else { throw failure("Install the helper for experimental closed-lid support.") }
            guard !unresolved, journal == nil else { throw failure("Global state needs review before another closed-lid session.") }
            guard env.sleepDisabled != nil else { throw failure("Cannot read SleepDisabled. Use ordinary keep-awake mode.") }
            guard env.lidClosed != nil else { throw failure("Cannot read lid state. Use ordinary keep-awake mode.") }
        }
        let token = try backend.makeToken()
        try backend.acquireAssertions(mode: options.mode)
        do {
            if options.closedLid && env.sleepDisabled == false {
                let intent = Journal(bootID: backend.bootID, phase: .intent)
                try backend.saveJournal(intent); journal = intent
                do { try backend.setSleepDisabled(true) }
                catch {
                    if backend.environment().sleepDisabled == false { try backend.clearJournal(); journal = nil }
                    else { unresolved = true }
                    throw error
                }
                guard backend.environment().sleepDisabled == true else {
                    unresolved = true; throw failure("Sleep-disable write could not be verified. Global state needs review.")
                }
                let confirmed = Journal(bootID: backend.bootID, phase: .confirmed)
                try backend.saveJournal(confirmed); journal = confirmed
            }
            session = Session(peer: peer, token: token, options: options, started: backend.now,
                              leaseEnd: backend.now + 45,
                              deadline: options.durationSeconds.map { backend.now + Double($0) },
                              borrowed: options.closedLid && env.sleepDisabled == true)
            message = "Session active."
            return token
        } catch {
            backend.releaseAssertions()
            if journal != nil { unresolved = true }
            message = error.localizedDescription
            throw error
        }
    }

    private func safetyReason(_ env: Environment, options: SessionOptions) -> String? {
        if env.thermal == .critical { return "Critical thermal state; protection stopped. Let the Mac cool before restarting." }
        if env.thermal == .serious && env.lidClosed != false {
            return "Serious thermal state with a closed or unknown lid; protection stopped."
        }
        if env.onBattery {
            guard let percent = env.batteryPercent else { return "Battery level is unavailable; protection stopped." }
            if percent <= options.batteryFloor { return "Battery reached the \(options.batteryFloor)% cutoff; protection stopped." }
        }
        return nil
    }

    private func markConflict(_ reason: String) {
        if var record = journal {
            record.phase = .conflicted
            do { try backend.saveJournal(record) } catch { /* Preserve unresolved state in memory as well. */ }
            journal = record; unresolved = true
        } else if backend.environment().sleepDisabled == nil { unresolved = true }
        session = nil; backend.releaseAssertions(); message = reason
    }

    private func end(_ reason: String) {
        let hadSession = session != nil
        session = nil
        backend.releaseAssertions()
        if hadSession { message = reason }
        if journal != nil { cleanup() }
        if backend.environment().sleepDisabled == true {
            message += " Global sleep disable remains enabled; normal sleep is not assured."
        }
    }

    private func cleanup() {
        guard let record = journal else { return }
        let observed = backend.environment().sleepDisabled
        // A known disabled flag requires no write. This also resolves a crash after restoration.
        if observed == false {
            do { try backend.clearJournal(); journal = nil; unresolved = false }
            catch { unresolved = true; message = "Could not clear recovery journal." }
            return
        }
        guard !record.baseline, record.bootID == backend.bootID, record.phase == .confirmed,
              observed == true else {
            unresolved = true
            message = "Global sleep state is unresolved. No automatic restoration was attempted; review Diagnostics."
            return
        }
        do {
            var restoring = record; restoring.phase = .restoring
            try backend.saveJournal(restoring); journal = restoring
            try backend.setSleepDisabled(false)
            guard backend.environment().sleepDisabled == false else { throw failure("Restoration could not be verified.") }
            try backend.clearJournal(); journal = nil; unresolved = false
        } catch {
            unresolved = true; message = "Sleep-setting restoration failed: \(error.localizedDescription)"
        }
    }

    private func failure(_ text: String) -> ServiceError { .failure(text) }
}
