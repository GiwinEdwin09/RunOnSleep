import Testing
import Foundation
import Darwin
@testable import RunOnSleepCore

struct TransportAndVerificationTests {
    @Test func testKernelPeerIdentityIsAvailable() throws {
        var sockets: [Int32] = [0, 0]
        expectEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        let peer = try UnixTransport.peer(sockets[0])
        expectEqual(peer.uid, getuid())
        expectEqual(peer.identity.count, MemoryLayout<audit_token_t>.size)
        expectTrue(peer.identity.contains { $0 != 0 })
    }
    @Test func testFramedRoundTripAndOversizedFrameRejection() throws {
        var sockets: [Int32] = [0, 0]
        expectEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        try UnixTransport.writeFrame(Request(.status), to: sockets[0])
        let decoded = try JSONDecoder().decode(Request.self, from: UnixTransport.readFrame(sockets[1]))
        expectEqual(decoded.operation, .status)
        let excessive = Data(repeating: 65, count: UnixTransport.maximumFrame + 1)
        let writer = sockets[0]
        UnixTransport.configure(writer)
        let group = DispatchGroup(); group.enter()
        DispatchQueue.global().async {
            _ = excessive.withUnsafeBytes { send(writer, $0.baseAddress, $0.count, 0) }
            group.leave()
        }
        expectThrows(try UnixTransport.readFrame(sockets[1]))
        expectEqual(group.wait(timeout: .now() + 3), .success)
    }
    @Test func testPipelinedFramesAreRejected() throws {
        var sockets: [Int32] = [0, 0]
        expectEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[0]); close(sockets[1]) }
        let data = Data("{}\n{}\n".utf8)
        _ = data.withUnsafeBytes { send(sockets[0], $0.baseAddress, $0.count, 0) }
        expectThrows(try UnixTransport.readFrame(sockets[1]))
    }
    @Test func testDisconnectBeforeNewlineIsRejected() throws {
        var sockets: [Int32] = [0, 0]
        expectEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        defer { close(sockets[1]) }
        close(sockets[0])
        expectThrows(try UnixTransport.readFrame(sockets[1]))
    }
    @Test func testVerificationRequiresBothTrialsAndCurrentConfiguration() {
        let configuration = Configuration(hardware: "Mac14,2", osBuild: "build", appVersion: "1", helperVersion: "1")
        let pass = Trial(durationSeconds: 1800, taskProgressConfirmed: true, sleepLogReviewed: true,
                         unexpectedSleep: false, powerTransitionsPassed: true, evidence: "Reviewed task.log and pmset.log")
        var record = VerificationRecord(configuration: configuration, testedAt: Date(), charger: pass, battery: pass)
        expectTrue(record.label(for: configuration).hasPrefix("Verified"))
        var changed = configuration; changed.osBuild = "updated"
        expectTrue(record.label(for: changed).hasPrefix("Untested"))
        record.battery.durationSeconds = 1799
        expectTrue(record.label(for: configuration).hasPrefix("Failed"))
        record.battery.durationSeconds = 1800; record.battery.evidence = ""
        expectTrue(record.label(for: configuration).hasPrefix("Failed"))
    }
}
