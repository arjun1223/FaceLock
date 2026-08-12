import AppKit
import CoreGraphics

@MainActor
final class WakeLockMonitor {
    private let settings: SecuritySettings
    private let coordinator: UnlockCoordinator
    private let workspaceCenter = NSWorkspace.shared.notificationCenter
    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var inputMonitor: Any?
    private var pendingAttempt: Task<Void, Never>?
    private var isLocked = false

    init(settings: SecuritySettings, coordinator: UnlockCoordinator) {
        self.settings = settings
        self.coordinator = coordinator
    }

    func start() {
        guard workspaceObservers.isEmpty else { return }
        coordinator.prepare()
        for name in [NSWorkspace.screensDidWakeNotification, NSWorkspace.didWakeNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleAttempt(reason: "display wake") }
            })
        }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            workspaceObservers.append(workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    self?.pendingAttempt?.cancel()
                    self?.coordinator.stop()
                }
            })
        }
        observeDistributed("com.apple.screenIsLocked") { [weak self] in
            guard let self else { return }
            self.isLocked = true
            self.startInputMonitor()
            self.scheduleAttempt(reason: "screen lock")
        }
        observeDistributed("com.apple.screenIsUnlocked") { [weak self] in
            guard let self else { return }
            self.isLocked = false
            self.pendingAttempt?.cancel()
            self.pendingAttempt = nil
            self.stopInputMonitor()
            self.coordinator.stop()
        }
    }

    func stop() {
        pendingAttempt?.cancel()
        pendingAttempt = nil
        stopInputMonitor()
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        distributedObservers.forEach(DistributedNotificationCenter.default().removeObserver)
        workspaceObservers.removeAll()
        distributedObservers.removeAll()
        coordinator.stop()
    }

    private func scheduleAttempt(reason: String, maximumDelay: Double? = nil) {
        guard isLocked, settings.faceUnlockEnabled else { return }
        pendingAttempt?.cancel()
        let configuredDelay = max(0, settings.unlockStartDelaySeconds)
        let delay = maximumDelay.map { min(configuredDelay, $0) } ?? configuredDelay
        settings.reportUnlockStatus(String(format: "Locked — face scan starts in %.1fs (%@)", delay, reason))
        pendingAttempt = Task { [weak self] in
            guard let self else { return }
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            guard self.isLocked, Self.isScreenActuallyLocked(), self.settings.faceUnlockEnabled else { return }
            self.coordinator.start()
            self.pendingAttempt = nil
        }
    }

    private func startInputMonitor() {
        guard inputMonitor == nil else { return }
        let triggerKeys: Set<UInt16> = [0x31, 0x24, 0x4C] // Space, Return, keypad Enter
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard triggerKeys.contains(event.keyCode) else { return }
            // A deliberate key press means loginwindow is already visible and its field
            // should be focused, so do not make the user wait through the wake delay.
            Task { @MainActor in self?.scheduleAttempt(reason: "Space/Return", maximumDelay: 0) }
        }
    }

    private func stopInputMonitor() {
        if let inputMonitor { NSEvent.removeMonitor(inputMonitor) }
        inputMonitor = nil
    }

    /// Queries the graphics-session server instead of trusting a spoofable notification.
    nonisolated static func isScreenActuallyLocked() -> Bool {
        guard let dictionary = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return (dictionary["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }

    private func observeDistributed(_ rawName: String, action: @escaping () -> Void) {
        let token = DistributedNotificationCenter.default().addObserver(forName: Notification.Name(rawName),
                                                                         object: nil,
                                                                         queue: .main) { _ in action() }
        distributedObservers.append(token)
    }
}
