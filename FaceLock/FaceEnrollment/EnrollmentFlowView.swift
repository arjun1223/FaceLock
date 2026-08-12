import SwiftUI
import CoreVideo
import Combine

private struct EnrollmentMotionTarget {
    let prompt: String
    let x: Double
    let y: Double
}

enum EnrollmentMotionPolicy {
    static let motionThreshold = 3.25
    static let targetAlignmentMinimum = 0.50
    static let minimumDirectionChangeDegrees = 12.0
    static let stableTicksRequired = 2

    static func angularDistance(from first: Double, to second: Double) -> Double {
        let difference = abs(first - second).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }

    static func hasAdvanced(from previous: Double?, to current: Double) -> Bool {
        guard let previous else { return true }
        return angularDistance(from: previous, to: current) >= minimumDirectionChangeDegrees
    }
}

struct EnrollmentFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraManager()
    @State private var capturedFrames: [CVPixelBuffer] = []
    @State private var isCapturing = false
    @State private var errorMessage: String?
    @State private var processingStatus: String?
    @State private var mirrorPreview = true
    @State private var neutralPose: FacePose?
    @State private var targetIndex = 0
    @State private var currentTargetProgress = 0.0
    @State private var physicalLeftSign: Double?
    @State private var physicalUpSign: Double?
    @State private var horizontalSignalSource: Int?
    @State private var verticalSignalSource: Int?
    @State private var stableTargetTicks = 0
    @State private var lastCompletedMotionAngle: Double?
    private let samplesPerPose = 2
    private let targets: [EnrollmentMotionTarget] = [
        .init(prompt: "Move your head slowly to the left", x: 1, y: 0),
        .init(prompt: "Continue toward the upper-left", x: 0.707, y: 0.707),
        .init(prompt: "Continue across the top", x: 0, y: 1),
        .init(prompt: "Continue toward the upper-right", x: -0.707, y: 0.707),
        .init(prompt: "Continue to the right", x: -1, y: 0),
        .init(prompt: "Continue toward the lower-right", x: -0.707, y: -0.707),
        .init(prompt: "Continue across the bottom", x: 0, y: -1),
        .init(prompt: "Finish at the lower-left", x: 0.707, y: -0.707)
    ]
    private let scanTimer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    let onCompleted: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Enroll Your Face").font(.largeTitle.bold()).foregroundStyle(Color.white)
                ZStack {
                    SegmentedProgressRing(progress: enrollmentProgress)
                        .frame(width: 380, height: 380)
                    CameraPreview(session: camera.session, isMirrored: mirrorPreview)
                        .frame(width: 300, height: 300)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(Color.white.opacity(0.45), lineWidth: 2) }
                }
                Text(scanPrompt)
                    .font(.title2.bold())
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
                Text(errorMessage ?? captureGuidance)
                    .foregroundStyle(errorMessage == nil ? Color.gray : Color.red)
                    .multilineTextAlignment(.center)
                Toggle("Mirror preview", isOn: $mirrorPreview)
                    .toggleStyle(.switch).fixedSize().foregroundStyle(Color.white)
                HStack {
                    Button("Cancel") { camera.stop(); dismiss() }
                    Button("Restart Scan") { resetScan() }.buttonStyle(.bordered)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 620, minHeight: 650)
        .onAppear { camera.requestAccessAndStart() }
        .onDisappear { camera.stop() }
        .onReceive(scanTimer) { _ in automaticCaptureTick() }
    }

    private var enrollmentProgress: Double {
        min((Double(targetIndex) + currentTargetProgress) / Double(targets.count), 1)
    }

    private var scanPrompt: String {
        if processingStatus != nil { return "Finishing your face scan" }
        if neutralPose == nil { return "Position your face in the circle" }
        guard targetIndex < targets.count else { return "Circle complete" }
        return targets[targetIndex].prompt
    }

    private var captureGuidance: String {
        if let processingStatus { return processingStatus }
        guard camera.pose.faceDetected else { return camera.statusText }
        if let guidance = camera.pose.enrollmentQualityGuidance { return guidance }
        if isCapturing { return "Nice — capturing that angle…" }
        if stableTargetTicks > 0 { return "Good — hold for just a moment…" }
        if neutralPose == nil { return "Hold still for the starting position…" }
        return "Move gradually to fill the ring — step \(min(targetIndex + 1, targets.count)) of \(targets.count)"
    }

    private func automaticCaptureTick() {
        guard camera.pose.isEnrollmentReady,
              !isCapturing,
              capturedFrames.count < (targets.count + 1) * samplesPerPose,
              processingStatus == nil else {
            stableTargetTicks = 0
            return
        }
        let pose = camera.pose
        guard let neutralPose else {
            self.neutralPose = pose
            capturePoseSamples(advanceTarget: false)
            return
        }

        guard targetIndex < targets.count else { return }
        let yawSignal = pose.yawDegrees - neutralPose.yawDegrees
        let noseXSignal = (pose.noseX - neutralPose.noseX) * 75
        let pitchSignal = pose.pitchDegrees - neutralPose.pitchDegrees
        let noseYSignal = (pose.noseY - neutralPose.noseY) * 75
        let horizontal: Double
        if horizontalSignalSource == 0 { horizontal = yawSignal }
        else if horizontalSignalSource == 1 { horizontal = noseXSignal }
        else { horizontal = dominantSignal(yawSignal, noseXSignal) }
        let vertical: Double
        switch verticalSignalSource {
        case 0: vertical = pitchSignal
        case 1: vertical = noseYSignal
        default: vertical = dominantSignal(pitchSignal, noseYSignal)
        }

        if targetIndex == 0 {
            currentTargetProgress = min(abs(horizontal) / EnrollmentMotionPolicy.motionThreshold, 1)
            let targetReached = abs(horizontal) >= EnrollmentMotionPolicy.motionThreshold
                && abs(horizontal) > abs(vertical) * 0.60
            guard heldStably(targetReached) else { return }
            horizontalSignalSource = abs(yawSignal) >= abs(noseXSignal) ? 0 : 1
            physicalLeftSign = horizontal >= 0 ? 1 : -1
            completeCurrentTarget(directionAngle: 0)
            return
        }

        guard let physicalLeftSign else { return }
        let logicalHorizontal = horizontal * physicalLeftSign
        if targetIndex == 1, physicalUpSign == nil {
            currentTargetProgress = min(min(max(logicalHorizontal, 0), abs(vertical)) / (EnrollmentMotionPolicy.motionThreshold * 0.55), 1)
            guard logicalHorizontal >= EnrollmentMotionPolicy.motionThreshold * 0.45,
                  abs(vertical) >= EnrollmentMotionPolicy.motionThreshold * 0.45 else {
                stableTargetTicks = 0
                return
            }
            let verticalSignals = [pitchSignal, noseYSignal]
            verticalSignalSource = verticalSignals.indices.max(by: {
                abs(verticalSignals[$0]) < abs(verticalSignals[$1])
            })
            physicalUpSign = vertical >= 0 ? 1 : -1
        }
        guard let physicalUpSign else { return }
        let logicalVertical = vertical * physicalUpSign
        let target = targets[targetIndex]
        let projection = max(0, logicalHorizontal * target.x + logicalVertical * target.y)
        let radius = hypot(logicalHorizontal, logicalVertical)
        let alignment = radius > 0 ? projection / radius : 0
        currentTargetProgress = min(projection / EnrollmentMotionPolicy.motionThreshold, 1)
        let directionAngle = atan2(logicalVertical, logicalHorizontal) * 180 / .pi
        let targetReached = projection >= EnrollmentMotionPolicy.motionThreshold
            && alignment >= EnrollmentMotionPolicy.targetAlignmentMinimum
            && EnrollmentMotionPolicy.hasAdvanced(from: lastCompletedMotionAngle, to: directionAngle)
        guard heldStably(targetReached) else { return }
        completeCurrentTarget(directionAngle: directionAngle)
    }

    private func dominantSignal(_ first: Double, _ second: Double) -> Double {
        abs(first) >= abs(second) ? first : second
    }

    private func heldStably(_ targetReached: Bool) -> Bool {
        guard targetReached else {
            stableTargetTicks = 0
            return false
        }
        stableTargetTicks += 1
        return stableTargetTicks >= EnrollmentMotionPolicy.stableTicksRequired
    }

    private func completeCurrentTarget(directionAngle: Double) {
        stableTargetTicks = 0
        capturePoseSamples(advanceTarget: true, completedAngle: directionAngle)
    }

    private func capturePoseSamples(advanceTarget: Bool, completedAngle: Double? = nil) {
        isCapturing = true
        errorMessage = nil
        Task {
            do {
                var poseFrames: [CVPixelBuffer] = []
                for sampleIndex in 0..<samplesPerPose {
                    guard camera.pose.isEnrollmentReady else { throw FaceEmbeddingError.poorCaptureQuality }
                    guard let buffer = camera.currentPixelBuffer() else { throw FaceEmbeddingError.noFace }
                    poseFrames.append(buffer)
                    if sampleIndex + 1 < samplesPerPose {
                        try await Task.sleep(for: .milliseconds(65))
                    }
                }
                capturedFrames.append(contentsOf: poseFrames)
                if advanceTarget {
                    lastCompletedMotionAngle = completedAngle
                    targetIndex += 1
                }
                currentTargetProgress = 0

                let expectedFrames = (targets.count + 1) * samplesPerPose
                guard capturedFrames.count >= expectedFrames else {
                    isCapturing = false
                    return
                }

                let framesToProcess = capturedFrames
                processingStatus = "Scan complete — analyzing \(framesToProcess.count) high-quality face samples…"
                let service = FaceEmbeddingService()
                var embeddings: [[Float]] = []
                for frame in framesToProcess {
                    embeddings.append(try await service.embedding(from: frame))
                }
                try FaceProfileStore.shared.save(embeddings: embeddings, samplesPerPose: samplesPerPose)
                processingStatus = "Face enrollment complete ✓"
                camera.stop()
                try? await Task.sleep(for: .seconds(0.8))
                onCompleted()
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                processingStatus = nil
                isCapturing = false
                if !advanceTarget { neutralPose = nil }
            }
        }
    }

    private func resetScan() {
        capturedFrames.removeAll()
        neutralPose = nil
        targetIndex = 0
        currentTargetProgress = 0
        physicalLeftSign = nil
        physicalUpSign = nil
        horizontalSignalSource = nil
        verticalSignalSource = nil
        stableTargetTicks = 0
        lastCompletedMotionAngle = nil
        isCapturing = false
        errorMessage = nil
        processingStatus = nil
    }
}

private struct SegmentedProgressRing: View {
    let progress: Double
    private let segmentCount = 64

    var body: some View {
        ZStack {
            ForEach(0..<segmentCount, id: \.self) { index in
                Capsule()
                    .fill(Double(index) < progress * Double(segmentCount)
                          ? Color.green
                          : Color.white.opacity(0.35))
                    .frame(width: 4, height: 18)
                    .offset(y: -176)
                    .rotationEffect(.degrees(Double(index) * 360 / Double(segmentCount)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: progress)
    }
}
