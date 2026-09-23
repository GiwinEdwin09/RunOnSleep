import AppKit
import SwiftUI
import ServiceManagement
import RunOnSleepCore

@MainActor
final class AppModel: ObservableObject {
    @Published var status: Status?
    @Published var helperAvailable = false
    @Published var error: String?
    @Published var busy = false
    @Published var connectionUncertain = false
    @Published var mode: SessionMode = .background
    @Published var closedLid = false
    @Published var duration = 0
    @Published var batteryFloor = 15.0
    @Published var showHeatWarning = false
    @Published var desktopLocked = false
    @Published var verification: VerificationRecord?
    @Published var loginEnabled = SMAppService.mainApp.status == .enabled
    private nonisolated let client = SessionClient()
    private nonisolated let worker = DispatchQueue(label: "com.runonsleep.client")
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var sessionActivity: NSObjectProtocol?
    private let verificationURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RunOnSleep/verification.json")

    init() {
        if let data = try? Data(contentsOf: verificationURL) {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            verification = try? decoder.decode(VerificationRecord.self, from: data)
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.desktopLocked = true } })
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.desktopLocked = false } })
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.worker.async { self.client.localSafetyTick() }
            Task { @MainActor in self.refresh() }
        })
        refresh()
    }

    var active: Bool { status?.active == true }
    private var observedHelperVersion: String {
        helperAvailable && !connectionUncertain ? (status?.helperVersion ?? "unavailable") : "unavailable"
    }
    var capability: String {
        verification?.label(for: .current(helperVersion: observedHelperVersion)) ?? "Untested on this configuration"
    }
    var interruption: String? {
        guard active, status?.options?.mode == .computerUse else { return nil }
        if desktopLocked { return "Computer use interrupted: unlock your desktop." }
        if status?.environment.lidClosed != false { return "Computer use needs an open lid." }
        return nil
    }

    func refresh() {
        guard !busy else { return }
        run { try $0.poll() }
    }

    func start() {
        if closedLid && mode == .background && !UserDefaults.standard.bool(forKey: "heatWarningAcknowledged") {
            showHeatWarning = true; return
        }
        startConfirmed()
    }

    func acknowledgeHeatWarning() {
        UserDefaults.standard.set(true, forKey: "heatWarningAcknowledged")
        showHeatWarning = false; startConfirmed()
    }

    private func startConfirmed() {
        if mode == .computerUse && desktopLocked { error = "Unlock the desktop before starting computer use."; return }
        let options = SessionOptions(mode: mode, closedLid: closedLid && mode == .background,
                                     durationSeconds: duration == 0 ? nil : duration, batteryFloor: Int(batteryFloor))
        run { try $0.start(options) }
    }

    func stop() { run { try $0.stop() } }

    func quit() {
        guard !busy else { return }
        run(quitAfter: true) { try $0.stop() }
    }

    private func run(quitAfter: Bool = false, _ action: @escaping (SessionClient) throws -> SessionClient.Update) {
        busy = true
        worker.async { [self] in
            let result = Result { try action(client) }
            DispatchQueue.main.async { [self] in
                busy = false
                switch result {
                case .success(let update):
                    connectionUncertain = false
                    status = update.status; helperAvailable = update.helperAvailable; error = update.error
                    if update.status.active && sessionActivity == nil {
                        // Keep lease-renewal timers running without adding an app-owned sleep assertion.
                        sessionActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep], reason: "Renew agent session lease")
                    } else if !update.status.active, let activity = sessionActivity {
                        ProcessInfo.processInfo.endActivity(activity); sessionActivity = nil
                    }
                case .failure(let failure):
                    connectionUncertain = true
                    error = failure.localizedDescription + " If contact was lost, the helper ends this app's lease within 45 seconds."
                }
                if quitAfter { NSApplication.shared.terminate(nil) }
            }
        }
    }

    func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginEnabled = SMAppService.mainApp.status == .enabled
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch { self.error = error.localizedDescription }
    }

    func openInstaller() {
        guard let url = Bundle.main.url(forResource: "RunOnSleepHelper", withExtension: "pkg") else {
            error = "Installer not found. Run Scripts/build.sh and use the packaged app."; return
        }
        NSWorkspace.shared.open(url)
    }

    func openGuide() {
        if let url = Bundle.main.url(forResource: "USER_GUIDE", withExtension: "md") { NSWorkspace.shared.open(url) }
    }

    func importVerification() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            guard data.count < 65536 else { throw ServiceError.failure("Verification record is too large.") }
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let record = try decoder.decode(VerificationRecord.self, from: data)
            guard record.testedAt <= Date() else { throw ServiceError.failure("Verification cannot be dated in the future.") }
            try FileManager.default.createDirectory(at: verificationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: verificationURL, options: .atomic)
            verification = record
        } catch { self.error = "Could not import verification: \(error.localizedDescription)" }
    }

    func copyDiagnostics() {
        let config = Configuration.current(helperVersion: observedHelperVersion)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var text = "RunOnSleep diagnostics (no session tokens)\n"
        if let data = try? encoder.encode(config), let value = String(data: data, encoding: .utf8) { text += value + "\n" }
        if let status, let data = try? encoder.encode(status), let value = String(data: data, encoding: .utf8) { text += value + "\n" }
        text += "Capability: \(capability)\nScreen-lock observations are best effort; the app never unlocks the desktop."
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
    }
}
