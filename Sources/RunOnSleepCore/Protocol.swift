import Foundation

public enum BuildInfo {
    public static let version = "0.1.0"
    public static let protocolVersion = 1
    public static let socketPath = "/var/run/com.runonsleep.helper/control.sock"
    public static let stateDirectory = "/Library/Application Support/RunOnSleep"
}

public enum SessionMode: String, Codable, CaseIterable {
    case background, computerUse
    public var title: String { self == .background ? "Background agents" : "Computer use" }
}

public enum Heat: Int, Codable { case nominal, fair, serious, critical }

public struct Environment: Codable, Equatable {
    public var sleepDisabled: Bool?
    public var onBattery: Bool
    public var batteryPercent: Int?
    public var lidClosed: Bool?
    public var thermal: Heat
    public var consoleUID: UInt32?
    public init(sleepDisabled: Bool? = false, onBattery: Bool = false, batteryPercent: Int? = 100,
                lidClosed: Bool? = false, thermal: Heat = .nominal, consoleUID: UInt32? = nil) {
        self.sleepDisabled = sleepDisabled; self.onBattery = onBattery; self.batteryPercent = batteryPercent
        self.lidClosed = lidClosed; self.thermal = thermal; self.consoleUID = consoleUID
    }
}

public struct SessionOptions: Codable, Equatable {
    public var mode: SessionMode
    public var closedLid: Bool
    public var durationSeconds: Int?
    public var batteryFloor: Int
    public init(mode: SessionMode = .background, closedLid: Bool = false,
                durationSeconds: Int? = nil, batteryFloor: Int = 15) {
        self.mode = mode; self.closedLid = closedLid; self.durationSeconds = durationSeconds
        self.batteryFloor = batteryFloor
    }
    public var isValid: Bool {
        (5...50).contains(batteryFloor) && [nil, 3600, 14400, 28800].contains(durationSeconds)
        && !(mode == .computerUse && closedLid)
    }
}

/// The kernel audit token includes process identity/version, unlike a reusable PID.
public struct Peer: Equatable {
    public let uid: UInt32
    public let identity: Data
    public init(uid: UInt32, identity: Data) { self.uid = uid; self.identity = identity }
}

public struct Request: Codable {
    public enum Operation: String, Codable { case start, renew, stop, status }
    public var version = BuildInfo.protocolVersion
    public var operation: Operation
    public var token: String?
    public var options: SessionOptions?
    public var sequence: UInt64?
    public init(_ operation: Operation, token: String? = nil, options: SessionOptions? = nil, sequence: UInt64? = nil) {
        self.operation = operation; self.token = token; self.options = options; self.sequence = sequence
    }
}

public struct Status: Codable {
    public var helperVersion = BuildInfo.version
    public var active: Bool
    public var options: SessionOptions?
    public var elapsedSeconds: Int
    public var remainingSeconds: Int?
    public var environment: Environment
    public var message: String
    public var unresolved: Bool
    public var borrowedGlobalSetting: Bool
    public var instanceID: String
}

public struct Response: Codable {
    public var version = BuildInfo.protocolVersion
    public var ok: Bool
    public var error: String?
    /// Only populated in a successful start response; never returned by status/renew/stop.
    public var token: String?
    public var status: Status
}

public enum ServiceError: LocalizedError {
    case failure(String)
    public var errorDescription: String? { if case .failure(let message) = self { return message }; return nil }
}

public struct Journal: Codable, Equatable {
    public enum Phase: String, Codable { case intent, confirmed, restoring, conflicted }
    public var bootID: String
    public var baseline: Bool = false
    public var phase: Phase
    public init(bootID: String, phase: Phase) { self.bootID = bootID; self.phase = phase }
}

public protocol PowerBackend: AnyObject {
    var bootID: String { get }
    var now: TimeInterval { get }
    func environment() -> Environment
    func acquireAssertions(mode: SessionMode) throws
    func releaseAssertions()
    func setSleepDisabled(_ enabled: Bool) throws
    func readJournal() throws -> Journal?
    func saveJournal(_ journal: Journal) throws
    func clearJournal() throws
    func makeToken() throws -> String
}
