import Testing
import Foundation
@testable import RunOnSleepCore

final class FakePower: PowerBackend {
    var bootID = "boot-A"
    var now: TimeInterval = 100
    var env = Environment(consoleUID: 501)
    var journal: Journal?
    var writes: [Bool] = []
    var assertions = false
    var failWrite = false
    var failReadJournal = false
    var failConfirm = false
    var failClear = false
    var failAssertions = false
    var readbackFails = false
    var failRestoreReadback = false
    var tokenCounter = 0
    func environment() -> Environment { env }
    func acquireAssertions(mode: SessionMode) throws {
        if failAssertions { throw ServiceError.failure("assertions unavailable") }; assertions = true
    }
    func releaseAssertions() { assertions = false }
    func setSleepDisabled(_ enabled: Bool) throws {
        writes.append(enabled)
        if failWrite { throw ServiceError.failure("write failed") }
        if readbackFails || (!enabled && failRestoreReadback) { env.sleepDisabled = nil }
        else { env.sleepDisabled = enabled }
    }
    func readJournal() throws -> Journal? {
        if failReadJournal { throw ServiceError.failure("corrupt journal") }; return journal
    }
    func saveJournal(_ journal: Journal) throws {
        if failConfirm && journal.phase == .confirmed { throw ServiceError.failure("disk full") }; self.journal = journal
    }
    func clearJournal() throws {
        if failClear { throw ServiceError.failure("clear failed") }; journal = nil
    }
    func makeToken() throws -> String { tokenCounter += 1; return "test-token-\(tokenCounter)" }
}

struct SessionEngineTests {
    let peer = Peer(uid: 501, identity: Data("audit-one".utf8))
    let closed = SessionOptions(closedLid: true)
    func setup(_ backend: FakePower) -> SessionEngine {
        let engine = SessionEngine(backend: backend, authorizedUID: 501); engine.recover(); return engine
    }
    func start(_ engine: SessionEngine, _ options: SessionOptions? = nil) -> Response {
        engine.handle(Request(.start, options: options ?? closed), peer: peer)
    }
    func stop(_ engine: SessionEngine, _ token: String?) -> Response {
        engine.handle(Request(.stop, token: token, sequence: 1), peer: peer)
    }

    @Test func testBorrowedGlobalStateIsNeverCleared() {
        let power = FakePower(); power.env.sleepDisabled = true
        let engine = setup(power); let response = start(engine)
        expectTrue(response.ok); expectTrue(response.status.borrowedGlobalSetting)
        expectTrue(stop(engine, response.token).ok)
        expectEqual(power.writes, []); expectEqual(power.env.sleepDisabled, true)
        expectTrue(engine.status().message.contains("not assured"))
    }
    @Test func testConfirmedChangeRestoresAndReleases() {
        let power = FakePower(); let engine = setup(power); let response = start(engine)
        expectTrue(response.ok); expectEqual(power.journal?.phase, .confirmed)
        expectTrue(stop(engine, response.token).ok)
        expectEqual(power.writes, [true, false]); expectNil(power.journal); expectFalse(power.assertions)
    }
    @Test func testOrdinarySessionNeverWritesGlobalState() {
        let power = FakePower(); power.env.sleepDisabled = nil
        let engine = setup(power); let response = start(engine, SessionOptions(mode: .computerUse))
        expectTrue(response.ok); _ = stop(engine, response.token)
        expectTrue(power.writes.isEmpty)
    }
    @Test func testExternalChangeEndsWithoutFightingIt() {
        let power = FakePower(); let engine = setup(power); _ = start(engine)
        power.env.sleepDisabled = false; engine.tick()
        expectFalse(engine.status().active); expectEqual(power.writes, [true])
        expectFalse(power.assertions); expectEqual(power.journal?.phase, .conflicted)
        power.env.sleepDisabled = true; engine.shutdown()
        expectEqual(power.writes, [true]); expectTrue(engine.status().unresolved)
    }
    @Test func testUnknownReadStopsAndPreventsRestoration() {
        let power = FakePower(); let engine = setup(power); _ = start(engine)
        power.env.sleepDisabled = nil; engine.tick(); engine.shutdown()
        expectFalse(engine.status().active); expectTrue(engine.status().unresolved)
        expectEqual(power.writes, [true])
    }
    @Test func testUnknownBaselineRejectsClosedModeButAllowsOrdinary() {
        let power = FakePower(); power.env.sleepDisabled = nil; let engine = setup(power)
        expectFalse(start(engine).ok); expectTrue(start(engine, SessionOptions()).ok)
    }
    @Test func testFailedWriteDoesNotReportActive() {
        let power = FakePower(); power.failWrite = true; let engine = setup(power)
        expectFalse(start(engine).ok); expectFalse(engine.status().active)
        expectFalse(power.assertions); expectNil(power.journal)
    }
    @Test func testSuccessfulExitWithoutReadbackIsNotSuccess() {
        let power = FakePower(); power.readbackFails = true; let engine = setup(power)
        expectFalse(start(engine).ok); expectTrue(engine.status().unresolved)
        expectEqual(power.journal?.phase, .intent); expectFalse(power.assertions)
    }
    @Test func testConfirmationPersistenceFailureRemainsAmbiguous() {
        let power = FakePower(); power.failConfirm = true; let engine = setup(power)
        expectFalse(start(engine).ok); expectEqual(power.journal?.phase, .intent)
        engine.shutdown(); expectEqual(power.writes, [true]); expectTrue(engine.status().unresolved)
    }
    @Test func testRestoreFailureIsVisibleAndNotRetriedBlindly() {
        let power = FakePower(); let engine = setup(power); let response = start(engine)
        power.failRestoreReadback = true; _ = stop(engine, response.token)
        expectTrue(engine.status().unresolved); expectFalse(power.assertions)
        expectEqual(power.journal?.phase, .restoring)
        power.env.sleepDisabled = true; engine.shutdown(); expectEqual(power.writes, [true, false])
    }
    @Test func testHelperRestartCleansConfirmedSameBootWithoutRevivingSession() {
        let power = FakePower(); let old = setup(power); let response = start(old)
        let restarted = setup(power)
        expectFalse(restarted.status().active); expectEqual(power.writes, [true, false])
        expectFalse(restarted.handle(Request(.renew, token: response.token, sequence: 1), peer: peer).ok)
    }
    @Test func testDifferentBootNeverReplaysRestoration() {
        let power = FakePower(); power.journal = Journal(bootID: "old-boot", phase: .confirmed)
        power.env.sleepDisabled = true; let engine = setup(power)
        expectTrue(engine.status().unresolved); expectTrue(power.writes.isEmpty)
        expectFalse(start(engine).ok); expectTrue(start(engine, SessionOptions()).ok)
    }
    @Test func testAmbiguousJournalDoesNotWrite() {
        for phase in [Journal.Phase.intent, .restoring, .conflicted] {
            let power = FakePower(); power.journal = Journal(bootID: power.bootID, phase: phase)
            power.env.sleepDisabled = true; let engine = setup(power)
            expectTrue(engine.status().unresolved); expectTrue(power.writes.isEmpty)
        }
    }
    @Test func testAlreadyClearedGlobalFlagOnlyClearsJournal() {
        let power = FakePower(); power.journal = Journal(bootID: "previous-boot", phase: .intent)
        let engine = setup(power)
        expectNil(power.journal); expectFalse(engine.status().unresolved); expectTrue(power.writes.isEmpty)
    }
    @Test func testCorruptJournalBlocksOnlyExperimentalMode() {
        let power = FakePower(); power.failReadJournal = true; let engine = setup(power)
        expectFalse(start(engine).ok); expectTrue(start(engine, SessionOptions()).ok)
        expectTrue(engine.status().unresolved)
    }
    @Test func testWrongTokenAndDifferentProcessCannotStopOrRenew() {
        let power = FakePower(); let engine = setup(power); let response = start(engine)
        expectFalse(stop(engine, "incorrect").ok)
        let other = Peer(uid: 501, identity: Data("audit-two".utf8))
        expectFalse(engine.handle(Request(.stop, token: response.token, sequence: 1), peer: other).ok)
        expectFalse(engine.handle(Request(.renew, token: response.token, sequence: 1), peer: other).ok)
        expectTrue(engine.status().active)
    }
    @Test func testUnauthorizedUserCannotStartOrReadStatus() {
        let power = FakePower(); let engine = setup(power)
        let other = Peer(uid: 502, identity: Data())
        expectFalse(engine.handle(Request(.start, options: closed), peer: other).ok)
        expectFalse(engine.handle(Request(.status), peer: other).ok)
        expectTrue(power.writes.isEmpty)
    }
    @Test func testCompetingStartsAndStaleSequenceRejected() {
        let power = FakePower(); let engine = setup(power); let response = start(engine)
        expectFalse(start(engine).ok)
        let request = Request(.renew, token: response.token, sequence: 1)
        expectTrue(engine.handle(request, peer: peer).ok)
        expectFalse(engine.handle(request, peer: peer).ok)
        expectFalse(stop(engine, response.token).ok)
        expectTrue(engine.handle(Request(.stop, token: response.token, sequence: 2), peer: peer).ok)
    }
    @Test func testLeaseExpiresEvenBeforeNextTickAndCannotRevive() {
        let power = FakePower(); let engine = setup(power); let response = start(engine)
        power.now += 45
        expectFalse(engine.handle(Request(.renew, token: response.token, sequence: 1), peer: peer).ok)
        expectFalse(engine.status().active); expectEqual(power.writes, [true, false])
    }
    @Test func testRenewalCannotExtendSessionDeadline() {
        let power = FakePower(); let engine = setup(power)
        let response = start(engine, SessionOptions(closedLid: true, durationSeconds: 3600))
        for n in 1...90 {
            power.now += 40
            let result = engine.handle(Request(.renew, token: response.token, sequence: UInt64(n)), peer: peer)
            expectEqual(result.ok, n < 90)
        }
        expectFalse(engine.status().active); expectEqual(power.writes, [true, false])
    }
    @Test func testBatteryCutoffIsIndependentOfGUI() {
        let power = FakePower(); let engine = setup(power); _ = start(engine)
        power.env.onBattery = true; power.env.batteryPercent = 20; engine.tick()
        expectTrue(engine.status().active); expectTrue(engine.status().message.contains("Low battery"))
        power.env.batteryPercent = 15; engine.tick()
        expectFalse(engine.status().active); expectFalse(power.assertions)
        power.env.onBattery = false; engine.tick(); expectFalse(engine.status().active)
    }
    @Test func testUnknownBatteryFailsSafeOnBattery() {
        let power = FakePower(); power.env.onBattery = true; power.env.batteryPercent = nil
        let engine = setup(power); expectFalse(start(engine).ok)
    }
    @Test func testSeriousHeatStopsClosedLidAndCriticalStopsOpen() {
        for closed in [true, false] {
            let power = FakePower(); let engine = setup(power); _ = start(engine)
            power.env.lidClosed = closed; power.env.thermal = .serious; engine.tick()
            expectEqual(engine.status().active, !closed)
            power.env.thermal = .critical; engine.tick()
            expectFalse(engine.status().active); expectFalse(power.assertions)
        }
    }
    @Test func testHotStartsRejectedAndNoAutomaticRestart() {
        let power = FakePower(); power.env.thermal = .critical; let engine = setup(power)
        expectFalse(start(engine).ok); power.env.thermal = .nominal; engine.tick()
        expectFalse(engine.status().active)
        power.env.thermal = .serious; power.env.lidClosed = true; expectFalse(start(engine).ok)
    }
    @Test func testComputerUseClosedLidStartAndInterruption() {
        let power = FakePower(); let engine = setup(power)
        let options = SessionOptions(mode: .computerUse)
        power.env.lidClosed = true; expectFalse(start(engine, options).ok)
        power.env.lidClosed = false; expectTrue(start(engine, options).ok)
        power.env.lidClosed = true; engine.tick()
        expectTrue(engine.status().message.contains("interrupted")); expectTrue(power.writes.isEmpty)
    }
    @Test func testLogoutEndsSession() {
        let power = FakePower(); let engine = setup(power); _ = start(engine)
        power.env.consoleUID = nil; engine.tick()
        expectFalse(engine.status().active); expectEqual(power.writes, [true, false])
    }
    @Test func testProtocolBoundsAndNoTokenInStatus() throws {
        let power = FakePower(); let engine = setup(power)
        expectFalse(start(engine, SessionOptions(batteryFloor: 0)).ok)
        expectFalse(start(engine, SessionOptions(durationSeconds: -1)).ok)
        expectFalse(start(engine, SessionOptions(mode: .computerUse, closedLid: true)).ok)
        var old = Request(.status); old.version = 99
        expectFalse(engine.handle(old, peer: peer).ok)
        let response = start(engine)
        let status = engine.handle(Request(.status), peer: peer)
        expectNil(status.token)
        let json = String(data: try JSONEncoder().encode(status), encoding: .utf8)!
        expectFalse(json.contains(response.token!))
    }
    @Test func testLocalEngineCannotChangeGlobalState() {
        let power = FakePower(); let engine = SessionEngine(backend: power, authorizedUID: 501, permitsGlobalWrites: false)
        expectFalse(start(engine).ok); expectTrue(start(engine, SessionOptions()).ok)
        expectTrue(power.writes.isEmpty)
    }
    @Test func testFailureToAcquireAssertionPreventsGlobalMutation() {
        let power = FakePower(); power.failAssertions = true; let engine = setup(power)
        expectFalse(start(engine).ok); expectTrue(power.writes.isEmpty)
    }
}
