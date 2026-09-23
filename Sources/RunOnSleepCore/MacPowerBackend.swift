import Foundation
import Darwin
import IOKit
import IOKit.pwr_mgt
import IOKit.ps
import Security
import SystemConfiguration

public final class MacPowerBackend: PowerBackend {
    private var assertions: [IOPMAssertionID] = []
    private let journalURL: URL?
    public let bootID: String
    public var now: TimeInterval {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(mach_continuous_time()) * Double(info.numer) / Double(info.denom) / 1_000_000_000
    }

    public init(journalURL: URL? = nil) {
        self.journalURL = journalURL
        self.bootID = Self.sysctlString("kern.bootsessionuuid") ?? "unavailable"
    }

    public static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0, size < 8192 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    public func environment() -> Environment {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        var disabled: Bool?, lid: Bool?
        if root != 0 {
            defer { IOObjectRelease(root) }
            disabled = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
            lid = IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        }
        var battery: Int?, onBattery = true
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() {
            if let source = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() {
                onBattery = (source as String) != kIOPSACPowerValue
            }
            let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
            for item in list {
                guard let entry = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                      entry[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                      let current = entry[kIOPSCurrentCapacityKey] as? Int,
                      let maximum = entry[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }
                battery = max(0, min(100, current * 100 / maximum))
            }
        }
        var uid: uid_t = 0, gid: gid_t = 0
        let user = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?
        return Environment(sleepDisabled: disabled, onBattery: onBattery, batteryPercent: battery,
                           lidClosed: lid, thermal: Heat(rawValue: ProcessInfo.processInfo.thermalState.rawValue) ?? .critical,
                           consoleUID: user != nil && user != "loginwindow" && uid != 0 ? uid : nil)
    }

    public func acquireAssertions(mode: SessionMode) throws {
        releaseAssertions()
        let types: [String] = mode == .computerUse
            ? [kIOPMAssertionTypePreventUserIdleSystemSleep, kIOPMAssertionTypePreventUserIdleDisplaySleep]
            : [kIOPMAssertionTypePreventUserIdleSystemSleep]
        for type in types {
            var id: IOPMAssertionID = 0
            let result = IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                    "RunOnSleep active agent session" as CFString, &id)
            guard result == kIOReturnSuccess else {
                releaseAssertions(); throw ServiceError.failure("Could not acquire a power assertion (\(result)).")
            }
            assertions.append(id)
        }
        if mode == .computerUse {
            var wake: IOPMAssertionID = 0
            if IOPMAssertionDeclareUserActivity("RunOnSleep computer-use session" as CFString, kIOPMUserActiveLocal, &wake) == kIOReturnSuccess {
                assertions.append(wake)
            }
        }
    }

    public func releaseAssertions() {
        for id in assertions { IOPMAssertionRelease(id) }
        assertions.removeAll()
    }

    public func setSleepDisabled(_ enabled: Bool) throws {
        guard geteuid() == 0, journalURL != nil, bootID != "unavailable" else {
            throw ServiceError.failure("A root helper with a known boot identity is required.")
        }
        // No shell; neither executable nor arguments originate from the client.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-a", "disablesleep", enabled ? "1" : "0"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = now + 3
        while process.isRunning && now < deadline { Thread.sleep(forTimeInterval: 0.02) }
        if process.isRunning {
            process.terminate(); usleep(100_000)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
            throw ServiceError.failure("pmset timed out; global state needs review.")
        }
        guard process.terminationStatus == 0 else { throw ServiceError.failure("pmset failed (\(process.terminationStatus)).") }
    }

    public func readJournal() throws -> Journal? {
        guard let url = journalURL, FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count < 4096 else { throw ServiceError.failure("Invalid journal size.") }
        return try JSONDecoder().decode(Journal.self, from: data)
    }

    public func saveJournal(_ journal: Journal) throws {
        guard let url = journalURL, bootID != "unavailable" else { throw ServiceError.failure("Durable recovery is unavailable.") }
        let data = try JSONEncoder().encode(journal)
        let temporary = url.appendingPathExtension("pending")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ServiceError.failure("Cannot open recovery journal.") }
        defer { close(fd) }
        let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
        guard count == data.count, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
            throw ServiceError.failure("Cannot persist recovery journal.")
        }
        try syncDirectory(url.deletingLastPathComponent())
    }

    public func clearJournal() throws {
        guard let url = journalURL else { return }
        if unlink(url.path) != 0 && errno != ENOENT { throw ServiceError.failure("Cannot remove recovery journal.") }
        try syncDirectory(url.deletingLastPathComponent())
    }

    private func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw ServiceError.failure("Cannot open journal directory.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw ServiceError.failure("Cannot sync journal directory.") }
    }

    public func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ServiceError.failure("Secure session-token generation failed.")
        }
        return Data(bytes).base64EncodedString()
    }

    deinit { releaseAssertions() }
}
