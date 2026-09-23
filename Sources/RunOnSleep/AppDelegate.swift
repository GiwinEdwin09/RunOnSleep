import AppKit
import SwiftUI
import CoreServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Both presentations use the same client, session token, and renewal timer.
    let model = AppModel()
    private var controlsWindow: NSWindow?
    private var finishedLaunching = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        finishedLaunching = true
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchReason = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
        let backgroundLaunch = event?.eventID == AEEventID(kAEOpenApplication)
            && (launchReason == keyAELaunchedAsLogInItem || launchReason == keyAELaunchedAsServiceItem)
        guard !backgroundLaunch else { return }
        showControls()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Initial launch is handled above, after its login-item context is available.
        if finishedLaunching { showControls() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func showControls() {
        let defaults = UserDefaults.standard
        let firstIntroduction = !defaults.bool(forKey: "hasSeenLaunchIntroduction")
        let window: NSWindow
        if let existing = controlsWindow {
            window = existing
        } else {
            let availableHeight = (NSScreen.main?.visibleFrame.height ?? 800) - 80
            window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 370, height: min(720, availableHeight)),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "RunOnSleep"
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
            controlsWindow = window
            window.center()
        }
        window.contentView = NSHostingView(rootView:
            ScrollView {
                ControlPanel(model: model, isLaunchPanel: true, showsMenuBarHint: firstIntroduction,
                             hidePanel: { [weak self] in self?.controlsWindow?.close() })
            }
            .frame(width: 370)
        )
        model.refresh()
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defaults.set(true, forKey: "hasSeenLaunchIntroduction")
    }
}
