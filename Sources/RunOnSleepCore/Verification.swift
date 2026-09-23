import Foundation

public struct Configuration: Codable, Equatable {
    public var hardware: String
    public var osBuild: String
    public var appVersion: String
    public var helperVersion: String
    public init(hardware: String, osBuild: String, appVersion: String, helperVersion: String) {
        self.hardware = hardware; self.osBuild = osBuild; self.appVersion = appVersion; self.helperVersion = helperVersion
    }
    public static func current(helperVersion: String) -> Configuration {
        Configuration(hardware: MacPowerBackend.sysctlString("hw.model") ?? "unknown",
                      osBuild: MacPowerBackend.sysctlString("kern.osversion") ?? "unknown",
                      appVersion: BuildInfo.version, helperVersion: helperVersion)
    }
}

public struct Trial: Codable {
    public var durationSeconds: Int
    public var taskProgressConfirmed: Bool
    public var sleepLogReviewed: Bool
    public var unexpectedSleep: Bool
    public var powerTransitionsPassed: Bool
    public var evidence: String
    public var passed: Bool {
        durationSeconds >= 1800 && taskProgressConfirmed && sleepLogReviewed && !unexpectedSleep
        && powerTransitionsPassed && !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public struct VerificationRecord: Codable {
    public var configuration: Configuration
    public var testedAt: Date
    public var charger: Trial
    public var battery: Trial
    public func label(for current: Configuration) -> String {
        guard configuration == current else { return "Untested — configuration changed" }
        return charger.passed && battery.passed ? "Verified on this configuration (experimental)" : "Failed verification — see trial evidence"
    }
}
