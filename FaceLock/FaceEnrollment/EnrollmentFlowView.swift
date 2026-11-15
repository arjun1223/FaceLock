import SwiftUI
import Combine
import CoreVideo

enum EnrollmentMotionPolicy {
    enum Pose: Equatable {
        case center, negativeYaw, positiveYaw
    }

    static func pose(yaw: Double, center: Double?, excluding completedSide: Pose? = nil) -> Pose? {
        if let center {
            let turn = yaw - center
            if turn <= -5, completedSide != .negativeYaw { return .negativeYaw }
            if turn >= 5, completedSide != .positiveYaw { return .positiveYaw }
        } else if abs(yaw) <= 14 {
            return .center
        }
        return nil
    }
}

enum EnrollmentRingDirection {
    static let segmentCount = 64

    static func segment(x: Double, y: Double, reflect: Bool) -> Int? {
        guard hypot(x, y) >= 0.025 else { return nil }
        let angle = atan2(reflect ? -x : x, -y)
        let index = Int((angle / (2 * .pi) * Double(segmentCount)).rounded())
        return (index + segmentCount) % segmentCount
    }

    static func arc(around segment: Int) -> Set<Int> {
        Set((-2...2).map { (segment + $0 + segmentCount) % segmentCount })
    }
}

struct EnrollmentFlowView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraManager()
    @State private var centerSamples: [[Float]] = []
    @State private var leftSamples: [[Float]] = []
    @State private var rightSamples: [[Float]] = []
    @State private var readyPose: EnrollmentMotionPolicy.Pose?
    @State private var readyFrames: [AnalyzedCameraFrame] = []
    @State private var lastSequence: UInt64?
    @State private var captureTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var processingStatus: String?
    @State private var mirrorPreview = true
    @State private var centerYaw: Double?
    @State private var useNoseForSide: Bool?
    @State private var neutralNose: CGPoint?
    @State private var activeSegment: Int?
    private let samplesPerPose = 3
    private var canCapture: Bool {
        readyFrames.count == samplesPerPose && captureTask == nil && processingStatus == nil
    }
    private let scanTimer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    let onCompleted: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Enroll Your Face").font(.largeTitle.bold()).foregroundStyle(Color.white)
                ZStack {
                    SegmentedProgressRing(active: activeSegment,
                                          mirrored: mirrorPreview,
                                          ready: canCapture)
                        .frame(width: 380, height: 380)
                    CameraPreview(session: camera.session, isMirrored: mirrorPreview)
                        .frame(width: 300, height: 300)
                        .clipShape(Circle())
                        .overlay { Circle().stroke(canCapture ? Color.green : Color.white.opacity(0.45), lineWidth: 2) }
                }
                Text(scanPrompt)
                    .font(.title2.bold())
                    .foregroundStyle(Color.white)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 430)
                Text(errorMessage ?? captureGuidance)
                    .foregroundStyle(errorMessage == nil ? Color.gray : Color.red)
                    .multilineTextAlignment(.center)
                Text("\(posesCaptured) of 3 poses captured")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.white)
                Toggle("Mirror preview", isOn: $mirrorPreview)
                    .toggleStyle(.switch).fixedSize().foregroundStyle(Color.white)
                Button(action: capturePose) {
                    Label(captureTask == nil ? "Capture Pose  ·  Space" : "Capturing…",
                          systemImage: "camera.fill")
                        .font(.title3.bold())
                        .frame(width: 310)
                        .padding(.vertical, 9)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.green)
                .keyboardShortcut(.space, modifiers: [])
                .disabled(!canCapture)
                HStack {
                    Button("Cancel") { captureTask?.cancel(); camera.stop(); dismiss() }
                    Button("Restart Scan") { resetScan() }
                }
                .buttonStyle(EnrollmentOutlineButtonStyle())
            }
            .padding(28)
        }
        .frame(minWidth: 620, minHeight: 650)
        .onAppear { camera.requestAccessAndStart() }
        .onDisappear {
            captureTask?.cancel()
            camera.stop()
        }
        .onReceive(scanTimer) { _ in updateCaptureGuide() }
    }

    private var scanPrompt: String {
        if processingStatus != nil { return "Finishing your face scan" }
        if centerSamples.count < samplesPerPose { return "Look straight at the camera" }
        if leftSamples.isEmpty && rightSamples.isEmpty { return "Turn your head slightly to either side" }
        if leftSamples.count == samplesPerPose || rightSamples.count == samplesPerPose {
            return "Turn your head slightly to the other side"
        }
        return "Turn your head slightly to either side"
    }

    private var captureGuidance: String {
        if let processingStatus { return processingStatus }
        guard camera.currentAnalyzedFrame(after: nil) != nil else {
            return camera.pose.faceDetected ? "Keep your eyes and mouth visible to the camera" : camera.statusText
        }
        if let guidance = camera.pose.enrollmentQualityGuidance { return guidance }
        if captureTask != nil { return "Processing the captured pose…" }
        return canCapture ? "Ready. Press Space to capture." : "Hold the requested pose until the ring turns green."
    }

    private var posesCaptured: Int {
        [centerSamples, leftSamples, rightSamples].filter { !$0.isEmpty }.count
    }

    private var completedSide: EnrollmentMotionPolicy.Pose? {
        if !leftSamples.isEmpty { return .negativeYaw }
        if !rightSamples.isEmpty { return .positiveYaw }
        return nil
    }

    private func updateCaptureGuide() {
        guard processingStatus == nil, captureTask == nil else { return }
        guard let frame = camera.currentAnalyzedFrame(after: nil, maximumAge: 0.35) else {
            activeSegment = nil
            clearReadyPose()
            return
        }
        guard frame.sequence != lastSequence else { return }
        lastSequence = frame.sequence
        updateRing(using: frame)
        guard let pose = eligiblePose(for: frame) else {
            clearReadyPose()
            return
        }
        if readyPose != pose {
            clearReadyPose()
            readyPose = pose
        }
        if readyFrames.count == samplesPerPose { readyFrames.removeFirst() }
        readyFrames.append(frame)
    }

    private func eligiblePose(for frame: AnalyzedCameraFrame) -> EnrollmentMotionPolicy.Pose? {
        guard frame.pose.isEnrollmentReady else { return nil }
        let yawPose = EnrollmentMotionPolicy.pose(yaw: frame.pose.yawDegrees, center: centerYaw)
        guard centerYaw != nil, let neutralNose else { return yawPose }
        let noseTurn = (Double(neutralNose.y) - frame.pose.noseY) * 125
        let nosePose = EnrollmentMotionPolicy.pose(yaw: noseTurn, center: 0)
        let pose = useNoseForSide == true ? nosePose
            : useNoseForSide == false ? yawPose : yawPose ?? nosePose
        return pose == completedSide ? nil : pose
    }

    private func clearReadyPose() {
        readyPose = nil
        readyFrames.removeAll()
    }

    private func capturePose() {
        guard canCapture, let pose = readyPose,
              let latest = camera.currentAnalyzedFrame(after: nil, maximumAge: 0.35),
              eligiblePose(for: latest) == pose else {
            return
        }
        let frames = readyFrames
        let usesNose = EnrollmentMotionPolicy.pose(yaw: latest.pose.yawDegrees, center: centerYaw) == nil
        clearReadyPose()
        captureTask = Task {
            defer { if !Task.isCancelled { captureTask = nil } }
            do {
                let service = FaceEmbeddingService()
                var samples: [[Float]] = []
                for frame in frames {
                    try Task.checkCancellation()
                    samples.append(try await service.embedding(from: frame.pixelBuffer, using: frame.alignment))
                }
                try Task.checkCancellation()
                errorMessage = nil
                switch pose {
                case .center:
                    let count = Double(frames.count)
                    centerYaw = frames.map(\.pose.yawDegrees).reduce(0, +) / count
                    neutralNose = CGPoint(x: frames.map(\.pose.noseX).reduce(0, +) / count,
                                          y: frames.map(\.pose.noseY).reduce(0, +) / count)
                    centerSamples = samples
                case .negativeYaw:
                    if useNoseForSide == nil { useNoseForSide = usesNose }
                    leftSamples = samples
                case .positiveYaw:
                    if useNoseForSide == nil { useNoseForSide = usesNose }
                    rightSamples = samples
                }
                if posesCaptured == 3 { saveEnrollment() }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = error.localizedDescription
            }
        }
    }

    private func updateRing(using frame: AnalyzedCameraFrame) {
        guard frame.pose.faceCount == 1, let neutralNose else {
            activeSegment = nil
            return
        }
        let box = frame.alignment.faceBoundingBox
        let aspect = Double(CVPixelBufferGetHeight(frame.pixelBuffer))
            / Double(CVPixelBufferGetWidth(frame.pixelBuffer))
        // Undo Vision's leftMirrored orientation to get the preview's unmirrored,
        // top-left coordinate system. Keep the offset relative to the face.
        let width = Double(box.height)
        let height = Double(box.width) * aspect
        let scale = max(width, height)
        guard scale > 0 else { return }
        let x = (Double(neutralNose.y) - frame.pose.noseY) * width / scale
        let y = (frame.pose.noseX - Double(neutralNose.x)) * height / scale
        activeSegment = EnrollmentRingDirection.segment(x: x, y: y, reflect: frame.isVideoMirrored)
    }

    private func saveEnrollment() {
        processingStatus = "Saving your face profile…"
        do {
            try FaceProfileStore.shared.save(embeddings: centerSamples + leftSamples + rightSamples,
                                             samplesPerPose: samplesPerPose)
            onCompleted()
            dismiss()
        } catch {
            processingStatus = "Select Restart Scan to try again."
            errorMessage = error.localizedDescription
        }
    }

    private func resetScan() {
        captureTask?.cancel()
        captureTask = nil
        centerSamples.removeAll()
        leftSamples.removeAll()
        rightSamples.removeAll()
        clearReadyPose()
        centerYaw = nil
        useNoseForSide = nil
        neutralNose = nil
        activeSegment = nil
        errorMessage = nil
        processingStatus = nil
    }
}

private struct EnrollmentOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 17)
            .padding(.vertical, 9)
            .background(Color.white.opacity(configuration.isPressed ? 0.22 : 0.06),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.white.opacity(0.65))
            }
    }
}

private struct SegmentedProgressRing: View {
    let active: Int?
    let mirrored: Bool
    let ready: Bool
    private let segmentCount = EnrollmentRingDirection.segmentCount

    var body: some View {
        let activeArc = active.map(EnrollmentRingDirection.arc(around:)) ?? []
        ZStack {
            ForEach(0..<segmentCount, id: \.self) { index in
                let sourceIndex = mirrored ? (segmentCount - index) % segmentCount : index
                Capsule()
                    .fill(ready ? Color.green
                          : activeArc.contains(sourceIndex) ? Color.teal
                          : Color.white.opacity(0.35))
                    .frame(width: 4, height: 18)
                    .offset(y: -176)
                    .rotationEffect(.degrees(Double(index) * 360 / Double(segmentCount)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: ready)
    }
}
