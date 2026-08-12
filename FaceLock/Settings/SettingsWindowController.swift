import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    private let securitySettings: SecuritySettings

    init(securitySettings: SecuritySettings) {
        self.securitySettings = securitySettings
        let root = SettingsView(securitySettings: securitySettings)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "FaceLock Settings"
        window.contentViewController = NSHostingController(rootView: root)
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func showEnrollment() {
        securitySettings.requestedAction = .enroll
        show()
    }

    func showPasswordSetup() {
        securitySettings.requestedAction = .password
        show()
    }
}
