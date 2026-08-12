import Foundation

enum SettingsAction: String, Identifiable {
    case enroll, password, test
    var id: String { rawValue }
}

@MainActor
final class SecuritySettings: ObservableObject {
    @Published var requestedAction: SettingsAction?
    @Published private(set) var lastUnlockStatus: String
    @Published var faceUnlockEnabled: Bool { didSet { defaults.set(faceUnlockEnabled, forKey: "faceUnlockEnabled") } }
    @Published var similarityThreshold: Double { didSet { defaults.set(similarityThreshold, forKey: "similarityThreshold") } }
    @Published var livenessEnabled: Bool { didSet { defaults.set(livenessEnabled, forKey: "livenessEnabled") } }
    @Published var attentionCheckEnabled: Bool { didSet { defaults.set(attentionCheckEnabled, forKey: "attentionCheckEnabled") } }
    @Published var unlockStartDelaySeconds: Double { didSet { defaults.set(unlockStartDelaySeconds, forKey: "unlockStartDelaySeconds") } }
    private let defaults = UserDefaults.standard

    init() {
        requestedAction = nil
        lastUnlockStatus = defaults.string(forKey: "lastUnlockStatus") ?? "No unlock attempt yet"
        faceUnlockEnabled = defaults.object(forKey: "faceUnlockEnabled") as? Bool ?? true
        similarityThreshold = defaults.object(forKey: "similarityThreshold") as? Double ?? 0.45
        livenessEnabled = defaults.object(forKey: "livenessEnabled") as? Bool ?? true
        attentionCheckEnabled = defaults.object(forKey: "attentionCheckEnabled") as? Bool ?? true
        let storedDelay = defaults.object(forKey: "unlockStartDelaySeconds") as? Double
        if storedDelay == nil {
            unlockStartDelaySeconds = 0
        } else if !defaults.bool(forKey: "didMigrateInstantWakeDelay"),
                  abs((storedDelay ?? 0) - 1.0) < 0.001 {
            unlockStartDelaySeconds = 0
            defaults.set(0.0, forKey: "unlockStartDelaySeconds")
        } else {
            unlockStartDelaySeconds = storedDelay ?? 0
        }
        defaults.set(true, forKey: "didMigrateFastWakeDelay")
        defaults.set(true, forKey: "didMigrateInstantWakeDelay")
    }

    func reportUnlockStatus(_ status: String) {
        lastUnlockStatus = status
        defaults.set(status, forKey: "lastUnlockStatus")
    }

    /// Updates live scan feedback without synchronously persisting intermediate
    /// frame-by-frame text on the recognition hot path.
    func reportTransientUnlockStatus(_ status: String) {
        lastUnlockStatus = status
    }

    func armFaceUnlockSession() async throws {
        if !PasswordVault.shared.isArmed {
            try await PasswordVault.shared.armSession()
        }
        try FaceProfileStore.shared.prepareForLockedSession()
        try FaceEmbeddingService.prewarm()
        reportUnlockStatus("Vault key and face profile are ready for this FaceLock session")
    }

    func faceProfileDidReEnroll() {
        // The upgraded scorer blends AdaFace gallery and centroid cosine similarities.
        // Reset after enrollment so an old experimental value cannot weaken the new gate.
        similarityThreshold = 0.45
        objectWillChange.send()
    }

}
