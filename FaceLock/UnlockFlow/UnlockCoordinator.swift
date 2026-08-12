import Foundation
import Combine

@MainActor
final class UnlockCoordinator {
    private let settings: SecuritySettings
    private let camera = CameraManager()
    private var poseObservation: AnyCancellable?
    private var timeoutTask: Task<Void, Never>?
    private var isVerifying = false
    private var attemptStartedAt: Date?

    init(settings: SecuritySettings) { self.settings = settings }

    func prepare() {
        camera.prepare()
        Task.detached(priority: .utility) {
            try? FaceEmbeddingService.prewarm()
        }
    }

    func start() {
        guard settings.faceUnlockEnabled else { return }
        guard FaceProfileStore.shared.isEnrolled else {
            settings.reportUnlockStatus("Face enrollment is missing")
            return
        }
        guard PasswordVault.shared.hasPassword else {
            settings.reportUnlockStatus("Password vault is not configured")
            return
        }
        guard PasswordVault.shared.isArmed else {
            settings.reportUnlockStatus("Face unlock is not armed — open Security settings and release the vault key with Touch ID")
            return
        }
        guard FaceProfileStore.shared.isPreparedForLockedSession else {
            settings.reportUnlockStatus("Face profile is not prepared — open Security settings and arm this FaceLock session")
            return
        }
        guard poseObservation == nil else { return }
        attemptStartedAt = Date()
        settings.reportUnlockStatus(settings.attentionCheckEnabled
                                    ? "Camera active — look directly at the camera"
                                    : "Camera active — looking for face movement")
        camera.requestAccessAndStart()
        poseObservation = camera.$pose.sink { [weak self] pose in
            guard let self, !self.isVerifying else { return }
            guard pose.isRecognitionReady else {
                if pose.faceDetected, let guidance = pose.qualityGuidance {
                    self.settings.reportTransientUnlockStatus(guidance)
                }
                return
            }
            guard !self.settings.attentionCheckEnabled || pose.isLookingAtCamera else {
                self.settings.reportTransientUnlockStatus(String(format: "Face detected at %.0f° — open both eyes and look at the camera",
                                                                 pose.facingAngleDegrees))
                return
            }
            self.verifyFreshFrames()
        }
        timeoutTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(12)) }
            catch { return }
            self?.settings.reportUnlockStatus("Timed out before a face/liveness match")
            self?.stop()
        }
    }

    func stop() {
        timeoutTask?.cancel(); timeoutTask = nil
        poseObservation?.cancel(); poseObservation = nil
        camera.stop(); isVerifying = false; attemptStartedAt = nil
    }

    private func verifyFreshFrames() {
        isVerifying = true
        camera.suppressPublishedPoseUpdates()
        let attemptStartedAt = self.attemptStartedAt ?? Date()
        Task {
            defer { stop() }
            do {
                var allScores: [Double] = []
                var allAttentionSamples: [Bool] = []
                var livenessChallenge = LivenessChallenge()
                var livenessPassed = !settings.livenessEnabled
                var acceptedDecision: FaceMatchDecision?
                let maximumSamples = settings.livenessEnabled ? 9 : FaceMatchEvaluator.requiredSampleCount
                var lastFrameSequence: UInt64?

                for index in 0..<maximumSamples {
                    guard let frame = await nextAnalyzedFrame(after: lastFrameSequence) else {
                        throw FaceEmbeddingError.noFace
                    }
                    lastFrameSequence = frame.sequence
                    let pose = frame.pose
                    guard pose.isRecognitionReady else {
                        throw FaceEmbeddingError.poorCaptureQuality
                    }
                    let embedding = try await FaceEmbeddingService().embedding(from: frame.pixelBuffer,
                                                                                using: frame.alignment)
                    allScores.append(try FaceProfileStore.shared.bestSimilarity(for: embedding))
                    allAttentionSamples.append(pose.isLookingAtCamera)
                    livenessPassed = livenessPassed || livenessChallenge.verify(pose)

                    let recentEyes = allAttentionSamples.suffix(FaceMatchEvaluator.requiredSampleCount)
                    let eyeVotes = recentEyes.filter { $0 }.count
                    let shownCount = min(index + 1, FaceMatchEvaluator.requiredSampleCount)
                    settings.reportTransientUnlockStatus("One-pass face scan — \(shownCount)/\(FaceMatchEvaluator.requiredSampleCount), eyes \(eyeVotes)")

                    if allScores.count < FaceMatchEvaluator.requiredSampleCount,
                       livenessPassed,
                       let decision = FaceMatchEvaluator.decisiveEarlyMatch(scores: allScores,
                                                                            threshold: settings.similarityThreshold),
                       (!settings.attentionCheckEnabled || EyeAttentionEvaluator.passedEarly(samples: allAttentionSamples)) {
                        acceptedDecision = decision
                        break
                    }

                    if allScores.count >= FaceMatchEvaluator.requiredSampleCount, livenessPassed {
                        let recentScores = Array(allScores.suffix(FaceMatchEvaluator.requiredSampleCount))
                        let recentAttention = Array(allAttentionSamples.suffix(FaceMatchEvaluator.requiredSampleCount))
                        guard let decision = FaceMatchEvaluator.decision(scores: recentScores,
                                                                          threshold: settings.similarityThreshold) else {
                            throw FaceEmbeddingError.noFace
                        }
                        guard decision.passed else {
                            settings.reportUnlockStatus(String(format: "Face not recognized — median %.2f, range %.2f–%.2f, %d/%d passed",
                                                               decision.medianScore, decision.minimumScore, decision.maximumScore,
                                                               decision.passingSamples, FaceMatchEvaluator.requiredSampleCount))
                            return
                        }
                        if !settings.attentionCheckEnabled || EyeAttentionEvaluator.passed(samples: recentAttention) {
                            acceptedDecision = decision
                            break
                        }
                    }

                }

                guard livenessPassed else {
                    settings.reportUnlockStatus("Unlock rejected — no live face movement was measured during the scan")
                    return
                }
                guard let decision = acceptedDecision else {
                    settings.reportUnlockStatus("Unlock rejected — keep both eyes open and look directly at the camera through the final frame")
                    return
                }
                let score = decision.medianScore
                guard WakeLockMonitor.isScreenActuallyLocked() else {
                    settings.reportUnlockStatus("Face matched, but the authoritative CGSession state says the screen is no longer locked")
                    return
                }
                settings.reportUnlockStatus(String(format: "Face recognized — median %.2f, %d/%d passed; typing with paced HID events",
                                                   score, decision.passingSamples, FaceMatchEvaluator.requiredSampleCount))
                var password = try await PasswordVault.shared.retrieve()
                guard WakeLockMonitor.isScreenActuallyLocked() else {
                    password.resetBytes(in: password.indices)
                    settings.reportUnlockStatus("Unlock cancelled because the screen became unlocked before typing")
                    return
                }
                try PasswordAutotyper().typePasswordAndSubmit(&password)
                var didUnlock = false
                for _ in 0..<12 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !WakeLockMonitor.isScreenActuallyLocked() {
                        didUnlock = true
                        break
                    }
                }
                if !didUnlock {
                    settings.reportUnlockStatus(String(format: "Identity passed (%.2f) and HID events were posted, but macOS remained locked", score))
                } else {
                    let duration = Date().timeIntervalSince(attemptStartedAt)
                    settings.reportUnlockStatus(String(format: "Unlocked in %.2fs after face match %.2f", duration, score))
                    UnlockSuccessOverlayController.shared.show()
                }
            } catch {
                settings.reportUnlockStatus("Face matched, but unlock stopped: \(error.localizedDescription)")
                NSLog("FaceLock unlock attempt stopped: %@", error.localizedDescription)
            }
        }
    }

    private func nextAnalyzedFrame(after sequence: UInt64?) async -> AnalyzedCameraFrame? {
        for _ in 0..<30 {
            if let frame = camera.currentAnalyzedFrame(after: sequence) { return frame }
            do { try await Task.sleep(for: .milliseconds(8)) }
            catch { return nil }
        }
        return nil
    }
}
