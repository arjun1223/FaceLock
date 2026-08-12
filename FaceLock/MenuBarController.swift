import AppKit
import Combine

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let settings: SecuritySettings
    private let openSettings: () -> Void
    private let reEnroll: () -> Void
    private let updatePassword: () -> Void
    private var cancellables = Set<AnyCancellable>()

    init(settings: SecuritySettings, openSettings: @escaping () -> Void,
         reEnroll: @escaping () -> Void, updatePassword: @escaping () -> Void) {
        self.settings = settings
        self.openSettings = openSettings
        self.reEnroll = reEnroll
        self.updatePassword = updatePassword
        super.init()
        statusItem.button?.image = NSImage(systemSymbolName: "faceid", accessibilityDescription: "FaceLock")
        statusItem.button?.toolTip = "FaceLock"
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        settings.$faceUnlockEnabled.sink { [weak self] _ in self?.statusItem.menu?.update() }.store(in: &cancellables)
        settings.$lastUnlockStatus.sink { [weak self] _ in self?.statusItem.menu?.update() }.store(in: &cancellables)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "FaceLock", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        let enabled = NSMenuItem(title: "Enable Face Unlock", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self; enabled.state = settings.faceUnlockEnabled ? .on : .off
        menu.addItem(enabled)
        let enroll = NSMenuItem(title: FaceProfileStore.shared.isEnrolled ? "Re-enroll Face…" : "Enroll Face…", action: #selector(beginEnrollment), keyEquivalent: "")
        enroll.target = self; menu.addItem(enroll)
        let password = NSMenuItem(title: PasswordVault.shared.hasPassword ? "Update Stored Password…" : "Set Up Password Vault…", action: #selector(beginPasswordSetup), keyEquivalent: "")
        password.target = self; menu.addItem(password)
        menu.addItem(.separator())
        let status = NSMenuItem(title: "Status: \(settings.lastUnlockStatus)", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit FaceLock", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) { settings.faceUnlockEnabled.toggle() }
    @objc private func beginEnrollment() { reEnroll() }
    @objc private func beginPasswordSetup() { updatePassword() }
    @objc private func showSettings() { openSettings() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}
