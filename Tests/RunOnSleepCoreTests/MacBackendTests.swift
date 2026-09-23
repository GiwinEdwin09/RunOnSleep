import Foundation
import Testing
import IOKit.pwr_mgt
import Darwin
@testable import RunOnSleepCore

@Suite(.serialized)
struct MacBackendTests {
    @Test func testRealPowerReadbackAndRandomTokens() throws {
        let backend = MacPowerBackend()
        let environment = backend.environment()
        #expect(environment.sleepDisabled != nil)
        #expect(environment.lidClosed != nil)
        #expect(environment.batteryPercent != nil)
        #expect(backend.bootID != "unavailable")
        let first = try backend.makeToken(), second = try backend.makeToken()
        #expect(first != second)
        #expect(Data(base64Encoded: first)?.count == 32)
    }

    @Test func testRealIdleAssertionIsReleasedWithoutChangingGlobalSetting() throws {
        let backend = MacPowerBackend()
        let before = backend.environment().sleepDisabled
        func ownAssertions() -> Int {
            var assertions: Unmanaged<CFDictionary>?
            guard IOPMCopyAssertionsByProcess(&assertions) == kIOReturnSuccess,
                  let values = assertions?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return -1 }
            return values[NSNumber(value: getpid())]?.count ?? 0
        }
        let initial = ownAssertions()
        try backend.acquireAssertions(mode: .background)
        defer { backend.releaseAssertions() }
        #expect(ownAssertions() > initial)
        backend.releaseAssertions()
        #expect(ownAssertions() == initial)
        #expect(backend.environment().sleepDisabled == before)
    }

    @Test func testJournalRoundTripOnDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let backend = MacPowerBackend(journalURL: folder.appendingPathComponent("journal.json"))
        #expect(try backend.readJournal() == nil)
        let intent = Journal(bootID: backend.bootID, phase: .intent)
        try backend.saveJournal(intent)
        #expect(try backend.readJournal() == intent)
        let confirmed = Journal(bootID: backend.bootID, phase: .confirmed)
        try backend.saveJournal(confirmed)
        #expect(try backend.readJournal() == confirmed)
        try backend.clearJournal()
        #expect(try backend.readJournal() == nil)
    }
}
