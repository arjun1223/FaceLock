import SwiftUI
import AppKit

@main
struct FaceLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let securitySettings = SecuritySettings()
    private lazy var unlockCoordinator = UnlockCoordinator(settings: securitySettings)
    private lazy var wakeMonitor = WakeLockMonitor(settings: securitySettings, coordinator: unlockCoordinator)
    private lazy var settingsWindow = SettingsWindowController(securitySettings: securitySettings)
    private var menuBar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        menuBar = MenuBarController(settings: securitySettings,
                                    openSettings: { [weak self] in self?.settingsWindow.show() },
                                    reEnroll: { [weak self] in self?.settingsWindow.showEnrollment() },
                                    updatePassword: { [weak self] in self?.settingsWindow.showPasswordSetup() })
        wakeMonitor.start()
        if !UserDefaults.standard.bool(forKey: "didShowPermissionRationale") { settingsWindow.show() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        wakeMonitor.stop()
    }
}
