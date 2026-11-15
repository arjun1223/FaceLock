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
    @State private var lastSequence: UInt64?
    @State private var captureTask: Task<Void, Never>?
    @State private var errorMessage: String?
    @State private var processingStatus: String?
    @State private var mirrorPreview = true
    @State private var centerYaw: Double?
    @State private var neutralNose: CGPoint?
    @State private var visitedSegments: Set<Int> = []
    @State private var activeSegment: Int?
    private let samplesPerPose = 3
    private let scanTimer = Timer.publish(every: 0.06, on: .main, in: .common).autoconnect()
    let onCompleted: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Text("Enroll Your Face").font(.largeTitle.bold()).foregroundStyle(Color.white)
                ZStack {
                    SegmentedProgressRing(visited: visitedSegments,
                                          active: activeSegment,
                                          mirrored: mirrorPreview)
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
                Text(errorMessage.map { "\($0) Select Restart Scan to try again." } ?? captureGuidance)
                    .foregroundStyle(errorMessage == nil ? Color.gray : Color.red)
                    .multilineTextAlignment(.center)
                Toggle("Mirror preview", isOn: $mirrorPreview)
                    .toggleStyle(.switch).fixedSize().foregroundStyle(Color.white)
                HStack {
                    Button("Cancel") { captureTask?.cancel(); camera.stop(); dismiss() }
                    Button("Restart Scan") { resetScan() }.buttonStyle(.bordered)
                }
            }
            .padding(28)
        }
        .frame(minWidth: 620, minHeight: 650)
        .onAppear { camera.requestAccessAndStart() }
        .onDisappear {
            captureTask?.cancel()
            camera.stop()
        }
        .onReceive(scanTimer) { _ in automaticCaptureTick() }
    }

    private var scanPrompt: String {
        if errorMessage != nil { return "Couldn’t finish enrollment" }
        if processingStatus != nil { return "Finishing your face scan" }
        if centerSamples.count < samplesPerPose { return "Look straight at the camera" }
        if leftSamples.isEmpty && rightSamples.isEmpty { return "Turn your head slightly to either side" }
        if leftSamples.count == samplesPerPose || rightSamples.count == samplesPerPose {
            return "Turn your head slightly to the other side"
        }
        return "Turn slightly to either side and pause"
    }

    private var captureGuidance: String {
        if let processingStatus { return processingStatus }
        guard camera.currentAnalyzedFrame(after: nil) != nil else {
            return camera.pose.faceDetected ? "Keep your eyes and mouth visible to the camera" : camera.statusText
        }
        if let guidance = camera.pose.enrollmentQualityGuidance { return guidance }
        if centerSamples.count < samplesPerPose {
            return "Straight ahead: \(centerSamples.count) of \(samplesPerPose) samples"
        }
        let samples = centerSamples.count + leftSamples.count + rightSamples.count
        return "\(samples) of \(3 * samplesPerPose) samples captured"
    }

    private func automaticCaptureTick() {
        guard processingStatus == nil else { return }
        guard let frame = camera.currentAnalyzedFrame(after: nil) else {
            activeSegment = nil
            return
        }
        guard frame.sequence != lastSequence else { return }
        lastSequence = frame.sequence
        updateRing(using: frame)
        guard captureTask == nil, frame.pose.isEnrollmentReady,
              let pose = EnrollmentMotionPolicy.pose(yaw: frame.pose.yawDegrees,
                                                     center: centerSamples.count == samplesPerPose ? centerYaw : nil,
                                                     excluding: completedSide) else { return }
        captureSample(frame, pose: pose)
    }

    private var completedSide: EnrollmentMotionPolicy.Pose? {
        if leftSamples.count == samplesPerPose { return .negativeYaw }
        if rightSamples.count == samplesPerPose { return .positiveYaw }
        return nil
    }

    private func captureSample(_ frame: AnalyzedCameraFrame, pose: EnrollmentMotionPolicy.Pose) {
        captureTask = Task {
            defer { if !Task.isCancelled { captureTask = nil } }
            do {
                let sample = try await FaceEmbeddingService().embedding(from: frame.pixelBuffer,
                                                                         using: frame.alignment)
                try Task.checkCancellation()
                errorMessage = nil
                switch pose {
                case .center:
                    let count = Double(centerSamples.count + 1)
                    let yaw = frame.pose.yawDegrees
                    let nose = CGPoint(x: frame.pose.noseX, y: frame.pose.noseY)
                    let previousNose = neutralNose ?? nose
                    centerYaw = (centerYaw ?? yaw) + (yaw - (centerYaw ?? yaw)) / count
                    neutralNose = CGPoint(x: previousNose.x + (nose.x - previousNose.x) / CGFloat(count),
                                          y: previousNose.y + (nose.y - previousNose.y) / CGFloat(count))
                    centerSamples.append(sample)
                case .negativeYaw:
                    leftSamples.append(sample)
                case .positiveYaw:
                    rightSamples.append(sample)
                }
                if leftSamples.count == samplesPerPose && rightSamples.count == samplesPerPose {
                    saveEnrollment()
                }
            } catch FaceEmbeddingError.alignmentFailed {
                // Keep the accepted samples and try the next usable camera frame.
            } catch {
                guard !Task.isCancelled else { return }
                processingStatus = "Select Restart Scan to try again."
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
        if let activeSegment {
            visitedSegments.formUnion(EnrollmentRingDirection.arc(around: activeSegment))
        }
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
        centerYaw = nil
        neutralNose = nil
        visitedSegments.removeAll()
        activeSegment = nil
        errorMessage = nil
        processingStatus = nil
    }
}

private struct SegmentedProgressRing: View {
    let visited: Set<Int>
    let active: Int?
    let mirrored: Bool
    private let segmentCount = EnrollmentRingDirection.segmentCount

    var body: some View {
        let activeArc = active.map(EnrollmentRingDirection.arc(around:)) ?? []
        ZStack {
            ForEach(0..<segmentCount, id: \.self) { index in
                let sourceIndex = mirrored ? (segmentCount - index) % segmentCount : index
                Capsule()
                    .fill(activeArc.contains(sourceIndex) ? Color.green
                          : visited.contains(sourceIndex) ? Color.green.opacity(0.65)
                          : Color.white.opacity(0.35))
                    .frame(width: 4, height: 18)
                    .offset(y: -176)
                    .rotationEffect(.degrees(Double(index) * 360 / Double(segmentCount)))
            }
        }
        .animation(.easeOut(duration: 0.12), value: visited)
    }
}
