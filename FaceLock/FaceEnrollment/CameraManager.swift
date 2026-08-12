import AVFoundation
import Vision
import SwiftUI
import QuartzCore

struct FacePose: Equatable {
    var yawDegrees: Double = 0
    var pitchDegrees: Double = 0
    var rollDegrees: Double = 0
    var noseX: Double = 0.5
    var noseY: Double = 0.5
    var captureQuality: Double = 1
    var faceSize: Double = 1
    var confidence: Double = 1
    var faceCount = 1
    var eyeContactScore: Double = 1
    var eyeOpenness: Double = 1
    var pupilsDetected = true
    var faceDetected = false

    var isLookingAtCamera: Bool {
        pupilsDetected && eyeOpenness >= 0.10 && eyeContactScore >= 0.22
    }

    var isRecognitionReady: Bool {
        faceDetected
            && faceCount == 1
            && captureQuality >= 0.18
            && faceSize >= 0.16
            && confidence >= 0.5
    }

    var qualityGuidance: String? {
        guard faceDetected else { return "No face detected" }
        if faceCount != 1 { return "Only one face can be visible" }
        if faceSize < 0.16 { return "Move closer to the camera" }
        if captureQuality < 0.18 { return "Improve the lighting and hold the camera steady" }
        return nil
    }
}

struct FaceAlignmentGeometry: @unchecked Sendable {
    let faceBoundingBox: CGRect
    let leftEyeCenter: CGPoint
    let rightEyeCenter: CGPoint
    let mouthCenter: CGPoint
}

struct AnalyzedCameraFrame {
    let pixelBuffer: CVPixelBuffer
    let sequence: UInt64
    let pose: FacePose
    let alignment: FaceAlignmentGeometry
}

final class CameraManager: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    @Published private(set) var authorization: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .video)
    @Published private(set) var pose = FacePose()
    @Published private(set) var statusText = "Waiting for camera"
    private let captureQueue = DispatchQueue(label: "com.facelock.camera.capture", qos: .userInitiated)
    private let visionQueue = DispatchQueue(label: "com.facelock.camera.vision", qos: .userInitiated)
    private let bufferLock = NSLock()
    private var latestBuffer: CVPixelBuffer?
    private var latestBufferTime: CFTimeInterval = 0
    private var latestAnalyzedBuffer: CVPixelBuffer?
    private var latestAnalyzedBufferTime: CFTimeInterval = 0
    private var latestAnalyzedPose = FacePose()
    private var latestAlignment: FaceAlignmentGeometry?
    private var latestAnalyzedSequence: UInt64 = 0
    private var captureGeneration: UInt = 0
    private var acceptingFrames = false
    private var configured = false
    private var processingVision = false
    private var publishesPoseUpdates = true

    /// Builds the capture graph while the desktop is unlocked without turning the
    /// camera on. A later lock attempt only has to start the already-configured session.
    func prepare() {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else { return }
        captureQueue.async { [weak self] in _ = self?.configureIfNeeded() }
    }

    func requestAccessAndStart() {
        beginFreshCapture()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: configureAndStart()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorization = granted ? .authorized : .denied
                    if granted { self?.configureAndStart() }
                    else { self?.statusText = "Camera access was denied" }
                }
            }
        default:
            authorization = AVCaptureDevice.authorizationStatus(for: .video)
            statusText = "Enable camera access in System Settings → Privacy & Security → Camera"
        }
    }

    func stop() {
        publishesPoseUpdates = true
        invalidateCapturedFrames()
        captureQueue.async { [weak self] in self?.session.stopRunning() }
    }

    func suppressPublishedPoseUpdates() {
        publishesPoseUpdates = false
    }

    func currentPixelBuffer(maximumAge: TimeInterval = 0.75) -> CVPixelBuffer? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard acceptingFrames,
              latestBufferTime > 0,
              CACurrentMediaTime() - latestBufferTime <= maximumAge else { return nil }
        return latestBuffer
    }

    func currentAnalyzedFrame(after sequence: UInt64?, maximumAge: TimeInterval = 0.75) -> AnalyzedCameraFrame? {
        bufferLock.lock(); defer { bufferLock.unlock() }
        guard acceptingFrames,
              latestAnalyzedBufferTime > 0,
              CACurrentMediaTime() - latestAnalyzedBufferTime <= maximumAge,
              sequence == nil || latestAnalyzedSequence > sequence!,
              let latestAnalyzedBuffer,
              let latestAlignment else { return nil }
        return AnalyzedCameraFrame(pixelBuffer: latestAnalyzedBuffer,
                                   sequence: latestAnalyzedSequence,
                                   pose: latestAnalyzedPose,
                                   alignment: latestAlignment)
    }

    private func beginFreshCapture() {
        bufferLock.lock()
        captureGeneration &+= 1
        acceptingFrames = true
        latestBuffer = nil
        latestBufferTime = 0
        latestAnalyzedBuffer = nil
        latestAnalyzedBufferTime = 0
        latestAnalyzedPose = FacePose()
        latestAlignment = nil
        bufferLock.unlock()
        pose = FacePose()
    }

    private func invalidateCapturedFrames() {
        bufferLock.lock()
        captureGeneration &+= 1
        acceptingFrames = false
        latestBuffer = nil
        latestBufferTime = 0
        latestAnalyzedBuffer = nil
        latestAnalyzedBufferTime = 0
        latestAnalyzedPose = FacePose()
        latestAlignment = nil
        bufferLock.unlock()
        DispatchQueue.main.async { [weak self] in self?.pose = FacePose() }
    }

    private func configureAndStart() {
        captureQueue.async { [weak self] in
            guard let self else { return }
            guard self.configureIfNeeded() else { return }
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async { self.statusText = "Position your face in the frame" }
        }
    }

    private func configureIfNeeded() -> Bool {
        if configured { return true }
        session.beginConfiguration()
        session.sessionPreset = session.canSetSessionPreset(.hd1280x720) ? .hd1280x720 : .medium
        defer { session.commitConfiguration() }
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: camera), session.canAddInput(input) else {
            DispatchQueue.main.async { self.statusText = "No front camera is available" }
            return false
        }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: visionQueue)
        guard session.canAddOutput(output) else { return false }
        session.addOutput(output)
        if let connection = output.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = true
        }
        configured = true
        return true
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        bufferLock.lock()
        guard acceptingFrames else { bufferLock.unlock(); return }
        let generation = captureGeneration
        latestBuffer = pixelBuffer
        latestBufferTime = CACurrentMediaTime()
        bufferLock.unlock()
        guard !processingVision else { return }
        processingVision = true
        defer { processingVision = false }
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored)
        try? handler.perform([landmarksRequest, qualityRequest])

        bufferLock.lock()
        let isCurrentCapture = acceptingFrames && captureGeneration == generation
        bufferLock.unlock()
        guard isCurrentCapture else { return }

        let faces = landmarksRequest.results ?? []
        let face = faces.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        let qualityFaces = qualityRequest.results ?? []
        let qualityFace = qualityFaces.max(by: { $0.boundingBox.width < $1.boundingBox.width })
        let radiansToDegrees = 180.0 / Double.pi
        let nosePoints = face?.landmarks?.nose?.normalizedPoints ?? []
        let noseX = nosePoints.isEmpty ? 0.5 : nosePoints.map(\.x).reduce(0, +) / CGFloat(nosePoints.count)
        let noseY = nosePoints.isEmpty ? 0.5 : nosePoints.map(\.y).reduce(0, +) / CGFloat(nosePoints.count)

        func landmarkCenter(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
            guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
            let sum = points.reduce(CGPoint.zero) {
                CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
            }
            return CGPoint(x: sum.x / CGFloat(points.count),
                           y: sum.y / CGFloat(points.count))
        }

        func eyeMeasurement(eye: VNFaceLandmarkRegion2D?,
                            pupil: VNFaceLandmarkRegion2D?) -> (contact: Double, openness: Double)? {
            guard let eyePoints = eye?.normalizedPoints, eyePoints.count >= 4,
                  let pupilPoints = pupil?.normalizedPoints, !pupilPoints.isEmpty,
                  let minimumX = eyePoints.map(\.x).min(), let maximumX = eyePoints.map(\.x).max(),
                  let minimumY = eyePoints.map(\.y).min(), let maximumY = eyePoints.map(\.y).max() else {
                return nil
            }
            let width = maximumX - minimumX
            let height = maximumY - minimumY
            guard width > 0.001, height > 0.001 else { return nil }
            let pupilX = pupilPoints.map(\.x).reduce(0, +) / CGFloat(pupilPoints.count)
            let pupilY = pupilPoints.map(\.y).reduce(0, +) / CGFloat(pupilPoints.count)
            let centerX = (minimumX + maximumX) / 2
            let centerY = (minimumY + maximumY) / 2
            let horizontalOffset = abs(pupilX - centerX) / (width / 2)
            let verticalOffset = abs(pupilY - centerY) / (height / 2)
            // A broad center window handles normal landmark noise while rejecting a
            // pupil near an eye edge. Both eyes must independently satisfy the gate.
            let normalizedOffset = max(Double(horizontalOffset) / 0.78,
                                       Double(verticalOffset) / 0.90)
            return (max(0, 1 - normalizedOffset), Double(height / width))
        }

        let leftEye = eyeMeasurement(eye: face?.landmarks?.leftEye,
                                     pupil: face?.landmarks?.leftPupil)
        let rightEye = eyeMeasurement(eye: face?.landmarks?.rightEye,
                                      pupil: face?.landmarks?.rightPupil)
        let pupilsDetected = leftEye != nil && rightEye != nil
        let eyeContactScore = min(leftEye?.contact ?? 0, rightEye?.contact ?? 0)
        let eyeOpenness = min(leftEye?.openness ?? 0, rightEye?.openness ?? 0)
        let value = FacePose(yawDegrees: (face?.yaw?.doubleValue ?? 0) * radiansToDegrees,
                             pitchDegrees: (face?.pitch?.doubleValue ?? 0) * radiansToDegrees,
                             rollDegrees: (face?.roll?.doubleValue ?? 0) * radiansToDegrees,
                             noseX: Double(noseX),
                             noseY: Double(noseY),
                             captureQuality: Double(qualityFace?.faceCaptureQuality ?? 0),
                             faceSize: Double(min(face?.boundingBox.width ?? 0, face?.boundingBox.height ?? 0)),
                             confidence: Double(face?.confidence ?? 0),
                             faceCount: faces.count,
                             eyeContactScore: eyeContactScore,
                             eyeOpenness: eyeOpenness,
                             pupilsDetected: pupilsDetected,
                             faceDetected: face != nil)
        guard let face,
              let leftEyeCenter = landmarkCenter(face.landmarks?.leftEye),
              let rightEyeCenter = landmarkCenter(face.landmarks?.rightEye),
              let mouthCenter = landmarkCenter(face.landmarks?.outerLips) else { return }
        let alignment = FaceAlignmentGeometry(faceBoundingBox: face.boundingBox,
                                              leftEyeCenter: leftEyeCenter,
                                              rightEyeCenter: rightEyeCenter,
                                              mouthCenter: mouthCenter)
        bufferLock.lock()
        guard acceptingFrames, captureGeneration == generation else {
            bufferLock.unlock()
            return
        }
        latestAnalyzedBuffer = pixelBuffer
        latestAnalyzedBufferTime = CACurrentMediaTime()
        latestAnalyzedPose = value
        latestAlignment = alignment
        latestAnalyzedSequence &+= 1
        bufferLock.unlock()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.bufferLock.lock()
            let isStillCurrent = self.acceptingFrames && self.captureGeneration == generation
            self.bufferLock.unlock()
            guard isStillCurrent else { return }
            guard self.publishesPoseUpdates else { return }
            self.pose = value
            self.statusText = value.qualityGuidance ?? String(format: "Face ready — quality %.2f", value.captureQuality)
        }
    }
}

struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    var isMirrored = true

    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView(session: session)
        view.setMirrored(isMirrored)
        return view
    }

    func updateNSView(_ nsView: PreviewView, context: Context) {
        nsView.setMirrored(isMirrored)
    }

    final class PreviewView: NSView {
        private let previewLayer: AVCaptureVideoPreviewLayer
        private var isMirrored = true

        init(session: AVCaptureSession) {
            previewLayer = AVCaptureVideoPreviewLayer(session: session)
            super.init(frame: .zero)
            wantsLayer = true
            layer = CALayer()
            layer?.masksToBounds = true
            previewLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(previewLayer)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        func setMirrored(_ mirrored: Bool) {
            isMirrored = mirrored
            needsLayout = true
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            previewLayer.bounds = bounds
            previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            if let connection = previewLayer.connection, connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }
            previewLayer.setAffineTransform(CGAffineTransform(scaleX: isMirrored ? -1 : 1, y: 1))
            CATransaction.commit()
        }
    }
}
