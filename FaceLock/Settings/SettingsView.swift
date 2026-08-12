import SwiftUI
import AVFoundation
import ApplicationServices
import LocalAuthentication

struct SettingsView: View {
    @ObservedObject var securitySettings: SecuritySettings
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            FaceEnrollmentSettings(settings: securitySettings).tabItem { Label("Face Enrollment", systemImage: "faceid") }.tag(0)
            SecuritySettingsView(settings: securitySettings).tabItem { Label("Security", systemImage: "lock.shield") }.tag(1)
            AboutView().tabItem { Label("About", systemImage: "info.circle") }.tag(2)
        }
        .padding(20).frame(minWidth: 700, minHeight: 500)
        .sheet(item: $securitySettings.requestedAction) { action in
            switch action {
            case .enroll: EnrollmentFlowView { securitySettings.faceProfileDidReEnroll() }
            case .password: PasswordSetupView { securitySettings.objectWillChange.send() }
            case .test: FaceRecognitionTestView(settings: securitySettings)
            }
        }
    }
}

private struct FaceEnrollmentSettings: View {
    @ObservedObject var settings: SecuritySettings
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(FaceProfileStore.shared.isEnrolled ? "Face enrolled" : "No face enrolled",
                  systemImage: FaceProfileStore.shared.isEnrolled ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.title2.bold())
                .foregroundStyle(FaceProfileStore.shared.isEnrolled ? Color.green : Color.orange)
            Text("Guided poses are aligned and processed by the local AdaFace identity model. The encrypted 512-value embeddings are saved; camera images are not.")
                .foregroundStyle(.secondary)
            PermissionCard()
            HStack {
                Button(FaceProfileStore.shared.isEnrolled ? "Re-enroll Face…" : "Enroll Face…") { settings.requestedAction = .enroll }
                    .buttonStyle(.borderedProminent)
                if FaceProfileStore.shared.isEnrolled {
                    Button("Delete Face Data", role: .destructive) {
                        do { try FaceProfileStore.shared.delete(); message = "Encrypted face data was deleted."; settings.objectWillChange.send() }
                        catch { message = error.localizedDescription }
                    }
                }
            }
            if let message { Text(message).foregroundStyle(.secondary) }
            Spacer()
        }.padding()
    }
}

private struct PermissionCard: View {
    var body: some View {
        GroupBox("Required permissions") {
            VStack(alignment: .leading, spacing: 10) {
                Text("Camera: captures live frames for enrollment and matching. Frames never leave this Mac.")
                Text("Accessibility: permits paced HID-style password events after a successful face match. FaceLock types only while CGSession confirms the screen is locked.")
                HStack {
                    Button("Request Camera") { AVCaptureDevice.requestAccess(for: .video) { _ in } }
                    Button("Request Accessibility") { PasswordAutotyper.requestPermissions() }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(6)
        }
        .onAppear { UserDefaults.standard.set(true, forKey: "didShowPermissionRationale") }
    }
}

private struct SecuritySettingsView: View {
    @ObservedObject var settings: SecuritySettings
    @ObservedObject private var vault = PasswordVault.shared

    var body: some View {
        Form {
            Toggle("Enable wake face-unlock attempts", isOn: $settings.faceUnlockEnabled)
            Toggle("Require passive multi-frame movement liveness", isOn: $settings.livenessEnabled)
            Toggle("Require eyes looking at the camera", isOn: $settings.attentionCheckEnabled)
            LabeledContent("Identity model", value: "AdaFace IR101 · 65.2M parameters")
            VStack(alignment: .leading) {
                HStack {
                    Text("Automatic wake settling delay")
                    Spacer()
                    Text(settings.unlockStartDelaySeconds, format: .number.precision(.fractionLength(1))) + Text("s")
                }
                Slider(value: $settings.unlockStartDelaySeconds, in: 0...3, step: 0.1)
                Text("0 seconds is fastest. Increase this only if your Mac's camera or password screen is not ready reliably after wake.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading) {
                HStack { Text("Similarity threshold"); Spacer(); Text(settings.similarityThreshold, format: .number.precision(.fractionLength(2))) }
                Slider(value: $settings.similarityThreshold, in: 0.30...0.75, step: 0.01)
                Text("Blended AdaFace gallery + enrollment-centroid score. Higher values reject more impostors but may also reject you more often.").font(.caption).foregroundStyle(.secondary)
            }
            LabeledContent("Password vault", value: vault.hasPassword ? "Configured" : "Not configured")
            if vault.hasPassword {
                let sessionReady = vault.isArmed && FaceProfileStore.shared.isPreparedForLockedSession
                LabeledContent("Automatic unlock session", value: sessionReady ? "Armed" : "Preparation required")
                if !sessionReady {
                    Button("Arm Face Unlock for This Session…") {
                        Task {
                            do {
                                try await settings.armFaceUnlockSession()
                            } catch {
                                settings.reportUnlockStatus("Could not arm face unlock: \(error.localizedDescription)")
                            }
                        }
                    }
                }
            }
            LabeledContent("Last unlock attempt") {
                Text(settings.lastUnlockStatus).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
            }
            Button("Test Face Recognition…") { settings.requestedAction = .test }
                .buttonStyle(.borderedProminent)
            Text("Uses the same single-face quality gate and 5-of-7 fresh-frame decision as a real lock attempt. A pass cannot itself grant access to the protected macOS lock screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button(vault.hasPassword ? "Update Stored Password…" : "Set Up Password Vault…") { settings.requestedAction = .password }
            if vault.hasPassword {
                Button("Delete Stored Password", role: .destructive) { try? vault.delete(); settings.objectWillChange.send() }
            }
        }.formStyle(.grouped).padding()
    }
}

struct PasswordSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var confirmation = ""
    @State private var isAuthorized = false
    @State private var context: LAContext?
    @State private var status = "Touch ID is required before FaceLock will accept a macOS password."
    @State private var busy = false
    let onCompleted: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "touchid").font(.system(size: 48)).foregroundStyle(.blue)
            Text("Password Vault").font(.largeTitle.bold())
            Text(status).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 430)
            if isAuthorized {
                SecureField("macOS account password", text: $password).textFieldStyle(.roundedBorder).frame(width: 360)
                SecureField("Confirm password", text: $confirmation).textFieldStyle(.roundedBorder).frame(width: 360)
                Button("Encrypt and Store") { store() }.buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty || password != confirmation || busy)
            } else {
                Button("Authenticate with Touch ID") { authorize() }.buttonStyle(.borderedProminent).disabled(busy)
            }
            Button("Cancel") { dismiss() }.buttonStyle(.borderless)
        }.padding(36).frame(minWidth: 540, minHeight: 420)
    }

    private func authorize() {
        busy = true
        Task {
            do {
                context = try await BiometricGate().authorizedContext(reason: "Set up FaceLock's local password vault")
                isAuthorized = true; status = "Enter your real macOS account password. It will be encrypted immediately and never sent anywhere."
            } catch { status = error.localizedDescription }
            busy = false
        }
    }

    private func store() {
        guard let context else { return }
        busy = true
        do {
            try PasswordVault.shared.storeAfterBiometricAuthorization(password: password, context: context)
            try FaceProfileStore.shared.prepareForLockedSession()
            try FaceEmbeddingService.prewarm()
            password = ""; confirmation = ""; onCompleted(); dismiss()
        } catch { status = error.localizedDescription; busy = false }
    }
}

private struct FaceRecognitionTestView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var settings: SecuritySettings
    @StateObject private var camera = CameraManager()
    @State private var isTesting = false
    @State private var didPass: Bool?
    @State private var resultText = "Center your face, then run the test."
    @State private var mirrorPreview = true

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Text("Test Face Recognition").font(.largeTitle.bold()).foregroundStyle(Color.white)
                Text("Identity check only — this does not test macOS lock-screen input")
                    .font(.callout)
                    .foregroundStyle(Color.white.opacity(0.7))
                CameraPreview(session: camera.session, isMirrored: mirrorPreview)
                    .frame(width: 300, height: 300)
                    .clipShape(Circle())
                    .overlay {
                        Circle().stroke(resultColor, lineWidth: 7)
                    }
                if let didPass {
                    Image(systemName: didPass ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(didPass ? Color.green : Color.red)
                }
                Text(resultText)
                    .font(.title3.bold())
                    .foregroundStyle(resultColor)
                    .multilineTextAlignment(.center)
                Text(camera.pose.isLookingAtCamera
                     ? "Eyes looking at camera"
                     : (camera.pose.pupilsDetected ? "Look directly at the camera" : "Keep both open eyes clearly visible"))
                    .font(.callout.bold())
                    .foregroundStyle(camera.pose.isLookingAtCamera ? Color.green : Color.orange)
                if camera.pose.faceDetected {
                    Text(String(format: "Face angle %.0f° — supported through %.0f°",
                                camera.pose.facingAngleDegrees, FacePose.maximumFacingAngleDegrees))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(camera.pose.isWithinRecognitionAngle ? Color.white.opacity(0.7) : Color.orange)
                }
                Toggle("Mirror preview", isOn: $mirrorPreview)
                    .toggleStyle(.switch).fixedSize().foregroundStyle(Color.white)
                HStack {
                    Button("Close") { dismiss() }
                    Button(isTesting ? "Testing…" : "Run Recognition Test") { runTest() }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTesting || !camera.pose.isRecognitionReady || !FaceProfileStore.shared.isEnrolled)
                }
            }.padding(32)
        }
        .frame(minWidth: 560, minHeight: 590)
        .onAppear {
            if !FaceProfileStore.shared.isEnrolled { resultText = "No face profile is enrolled yet." }
            camera.requestAccessAndStart()
        }
        .onDisappear { camera.stop() }
    }

    private var resultColor: Color {
        guard let didPass else { return .white }
        return didPass ? .green : .red
    }

    private func runTest() {
        guard camera.currentPixelBuffer() != nil else {
            resultText = "No camera frame is ready yet."
            return
        }
        isTesting = true
        didPass = nil
        resultText = "Comparing with your encrypted enrollment…"
        Task {
            do {
                var scores: [Double] = []
                var attentionSamples: [Bool] = []
                for index in 0..<FaceMatchEvaluator.requiredSampleCount {
                    guard camera.pose.isRecognitionReady else { throw FaceEmbeddingError.poorCaptureQuality }
                    guard let buffer = camera.currentPixelBuffer() else { throw FaceEmbeddingError.noFace }
                    let embedding = try await FaceEmbeddingService().embedding(from: buffer)
                    scores.append(try FaceProfileStore.shared.bestSimilarity(for: embedding))
                    attentionSamples.append(camera.pose.isLookingAtCamera)
                    if index + 1 < FaceMatchEvaluator.requiredSampleCount {
                        try? await Task.sleep(for: .milliseconds(FaceMatchEvaluator.sampleIntervalMilliseconds))
                    }
                }
                guard let decision = FaceMatchEvaluator.decision(scores: scores,
                                                                  threshold: settings.similarityThreshold) else {
                    throw FaceEmbeddingError.noFace
                }
                let attentionPassed = !settings.attentionCheckEnabled
                    || EyeAttentionEvaluator.passed(samples: attentionSamples)
                let passed = decision.passed && attentionPassed
                didPass = passed
                resultText = String(format: "%@ — median %.2f (range %.2f–%.2f, face %d/%d, eyes %d/%d, threshold %.2f)",
                                    passed ? "PASS: Face and attention recognized" : "FAIL: Face or eye contact rejected",
                                    decision.medianScore, decision.minimumScore, decision.maximumScore,
                                    decision.passingSamples, FaceMatchEvaluator.requiredSampleCount,
                                    attentionSamples.filter { $0 }.count, FaceMatchEvaluator.requiredSampleCount,
                                    settings.similarityThreshold)
            } catch {
                didPass = false
                resultText = "Test failed: \(error.localizedDescription)"
            }
            isTesting = false
        }
    }
}

private struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("About FaceLock").font(.largeTitle.bold())
                Text("FaceLock is an unofficial, local-only portfolio/demo project. It is not Apple Face ID and it does not replace, intercept, or modify macOS loginwindow. It never disables System Integrity Protection.")
                Text("Important limitation").font(.title2.bold())
                Text("A normal third-party app has no supported login API. FaceLock experimentally mirrors HasBrain/FaceUnlock: after an authoritative locked-session check it posts one paced Unicode character at a time from a HID-system CGEvent source, followed by Return. OS behavior may change or reject these events.")
                Text("Security tradeoff").font(.title2.bold())
                Text("The account password is encrypted at rest with AES-256-GCM. Its random key is stored as a biometric-protected Keychain item. Even so, storing a login password creates risk: a bug, malware running as you, or a future OS behavior change could expose it briefly during decryption. Use this only on a test account and never as a substitute for FileVault or normal macOS authentication.")
                Text("No network code, analytics, telemetry, or cloud synchronization is included.").bold()
            }.frame(maxWidth: .infinity, alignment: .leading).padding()
        }
    }
}
