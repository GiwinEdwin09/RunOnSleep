import SwiftUI
import AppKit
import RunOnSleepCore

@main
struct RunOnSleepApp: App {
    @StateObject private var model = AppModel()
    var body: some Scene {
        MenuBarExtra {
            ControlPanel(model: model)
        } label: {
            Image(nsImage: model.connectionUncertain ? MenuBarIcon.unknown : (model.active ? MenuBarIcon.active : MenuBarIcon.inactive))
                .renderingMode(.template)
                .accessibilityLabel(model.connectionUncertain ? "RunOnSleep status unknown" : (model.active ? "RunOnSleep session active" : "RunOnSleep inactive"))
                .help(model.connectionUncertain ? "RunOnSleep — connection lost" : (model.active ? "RunOnSleep — protection active" : "RunOnSleep — inactive"))
        }
        .menuBarExtraStyle(.window)
    }
}

struct ControlPanel: View {
    @ObservedObject var model: AppModel
    @State private var showDiagnostics = false
    private var global: String {
        switch model.status?.environment.sleepDisabled {
        case true?: return "Enabled"
        case false?: return "Disabled"
        case nil: return "Unknown"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable().interpolation(.high).frame(width: 36, height: 36)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("RunOnSleep").font(.headline)
                    Text("Keep your agents working").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(model.connectionUncertain ? "UNKNOWN" : (model.active ? "ACTIVE" : "INACTIVE"))
                    .font(.caption2.bold()).padding(6)
                    .background(model.active ? Color.teal.opacity(0.15) : Color.gray.opacity(0.12), in: Capsule())
            }
            Divider()
            if model.active {
                LabeledContent("Session", value: model.status?.options?.mode.title ?? "Unknown")
                LabeledContent("Elapsed", value: clock(model.status?.elapsedSeconds ?? 0))
                if let remaining = model.status?.remainingSeconds { LabeledContent("Remaining", value: clock(remaining)) }
            } else {
                Picker("Mode", selection: $model.mode) {
                    ForEach(SessionMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                if model.mode == .background {
                    Toggle("Closed lid · experimental", isOn: $model.closedLid)
                    Text("No external monitor required. Needs the helper and hardware testing.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Keep the lid open and desktop unlocked. Screen-lock and password settings stay unchanged.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Duration", selection: $model.duration) {
                    Text("Until stopped").tag(0); Text("1 hour").tag(3600)
                    Text("4 hours").tag(14400); Text("8 hours").tag(28800)
                }
                HStack {
                    Text("Battery cutoff")
                    Slider(value: $model.batteryFloor, in: 5...50, step: 1).frame(maxWidth: 130)
                    Text("\(Int(model.batteryFloor))%").monospacedDigit().frame(width: 34)
                }
            }
            Button(action: { if model.active { model.stop() } else { model.start() } }) {
                Text(model.active ? "Stop protection" : "Start protection").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent).tint(.teal).controlSize(.large).disabled(model.busy)

            if let interruption = model.interruption {
                Label(interruption, systemImage: "desktopcomputer.trianglebadge.exclamationmark").foregroundStyle(.orange).font(.caption)
            }
            Text(model.connectionUncertain ? "Connection lost. Protection status is unconfirmed." : (model.status?.message ?? "Checking power status…"))
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            if let error = model.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            Divider()
            LabeledContent("Global SleepDisabled", value: model.connectionUncertain ? "Unknown" : global).font(.caption)
            if let env = model.status?.environment {
                LabeledContent(env.onBattery ? "Battery power" : "Charger connected",
                               value: env.batteryPercent.map { "\($0)%" } ?? "Level unavailable").font(.caption)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Closed-lid capability · experimental").font(.caption.bold())
                Text(model.capability).font(.caption).foregroundStyle(.secondary)
            }
            if model.closedLid || model.status?.options?.closedLid == true {
                Text("Use a hard, ventilated surface. Never run closed inside a bag or enclosure.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if !model.helperAvailable {
                Button("Install administrator helper…", action: model.openInstaller)
                Text("Ordinary keep-awake works without installation.").font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Diagnostics & settings", isExpanded: $showDiagnostics) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("SleepDisabled is a shared setting. Avoid running other sleep-management tools at the same time.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Launch at login", isOn: Binding(get: { model.loginEnabled }, set: model.setLogin))
                    Button("Copy diagnostics", action: model.copyDiagnostics)
                    Button("Import hardware trial results…", action: model.importVerification)
                    Button("Testing & recovery guide", action: model.openGuide)
                    if model.status?.unresolved == true {
                        Text("Global state needs review. Open the recovery guide before changing any system setting.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }.padding(.top, 6)
            }
            HStack {
                Text("v\(BuildInfo.version)").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit", action: model.quit).disabled(model.busy)
            }
        }
        .padding(18).frame(width: 370)
        .alert("Before running with the lid closed", isPresented: $model.showHeatWarning) {
            Button("Start experimental session", action: model.acknowledgeHeatWarning)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Keep the Mac on a hard, ventilated surface—never inside a bag or enclosure. Thermal protection can interrupt your task and is not a temperature guarantee. Closed-lid behavior uses an undocumented setting and remains untested until you complete hardware trials.")
        }
    }

    private func clock(_ seconds: Int) -> String {
        String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
}
