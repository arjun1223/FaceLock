import Foundation
import Vision
import CoreML
import CoreImage
import CoreVideo
import ImageIO

enum FaceEmbeddingError: LocalizedError {
    case noFace
    case landmarksUnavailable
    case alignmentFailed
    case modelUnavailable
    case predictionFailed
    case outdatedProfile
    case multipleFaces
    case faceTooSmall
    case poorCaptureQuality

    var errorDescription: String? {
        switch self {
        case .noFace:
            return "No face was detected."
        case .landmarksUnavailable:
            return "Keep your eyes and mouth visible to the camera."
        case .alignmentFailed:
            return "Face alignment failed. Face the camera and try again."
        case .modelUnavailable:
            return "The bundled AdaFace recognition model could not be loaded."
        case .predictionFailed:
            return "The face-recognition model could not process this frame."
        case .outdatedProfile:
            return "This profile uses the old matcher. Re-enroll your face to use the upgraded recognition pipeline."
        case .multipleFaces:
            return "Only one face can be visible during recognition."
        case .faceTooSmall:
            return "Move closer so your face fills more of the camera frame."
        case .poorCaptureQuality:
            return "The face frame is blurry, poorly lit, or too far off-angle."
        }
    }
}

/// Extracts a 512-dimensional identity embedding with the bundled 65.2M-parameter
/// AdaFace IR101 WebFace12M model.
/// Frames and embeddings stay on-device; camera images are never persisted.
struct FaceEmbeddingService {
    static let embeddingKind = "adaface-ir101-webface12m-aligned-quality-multisample-v1"
    static let modelDisplayName = "AdaFace IR101 WebFace12M"
    static let modelParameterCount = 65_150_912

    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    private final class SendablePixelBuffer: @unchecked Sendable {
        let value: CVPixelBuffer
        init(_ value: CVPixelBuffer) { self.value = value }
    }
    private static let model: MLModel? = {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all

        if let url = Bundle.main.url(forResource: "AdaFace_IR101", withExtension: "mlmodelc") {
            return try? MLModel(contentsOf: url, configuration: configuration)
        }

        // Xcode can preserve a containing group depending on how the model was added.
        if let urls = Bundle.main.urls(forResourcesWithExtension: "mlmodelc", subdirectory: nil),
           let url = urls.first(where: { $0.lastPathComponent.hasPrefix("AdaFace_IR101") }) {
            return try? MLModel(contentsOf: url, configuration: configuration)
        }
        return nil
    }()

    static var isBundledModelAvailable: Bool { model != nil }

    /// Loads and executes IR101 while the user session is unlocked so the first lock
    /// attempt does not pay Core ML compilation and Neural Engine warm-up latency.
    static func prewarm() throws {
        guard let model else { throw FaceEmbeddingError.modelUnavailable }
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        guard CVPixelBufferCreate(kCFAllocatorDefault, 112, 112,
                                  kCVPixelFormatType_32BGRA,
                                  attributes as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { throw FaceEmbeddingError.predictionFailed }
        Self.ciContext.render(CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5))
                                .cropped(to: CGRect(x: 0, y: 0, width: 112, height: 112)),
                              to: buffer)
        let input = try MLDictionaryFeatureProvider(dictionary: [
            "face_image": MLFeatureValue(pixelBuffer: buffer)
        ])
        _ = try model.prediction(from: input)
    }

    func embedding(from pixelBuffer: CVPixelBuffer) async throws -> [Float] {
        try await embedding(from: pixelBuffer, using: nil)
    }

    /// Lock-screen fast path. CameraManager has already performed the same Vision
    /// landmark request for pose, quality, liveness, and attention, so reuse that
    /// geometry instead of detecting the identical landmarks a second time.
    func embedding(from pixelBuffer: CVPixelBuffer,
                   using alignment: FaceAlignmentGeometry) async throws -> [Float] {
        try await embedding(from: pixelBuffer, using: Optional(alignment))
    }

    private func embedding(from pixelBuffer: CVPixelBuffer,
                           using alignment: FaceAlignmentGeometry?) async throws -> [Float] {
        let sendableBuffer = SendablePixelBuffer(pixelBuffer)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    guard let model = Self.model else { throw FaceEmbeddingError.modelUnavailable }
                    let alignedFace = try alignment.map {
                        try Self.alignedFace(from: sendableBuffer.value, using: $0)
                    } ?? Self.alignedFace(from: sendableBuffer.value)
                    let input = try MLDictionaryFeatureProvider(dictionary: [
                        "face_image": MLFeatureValue(pixelBuffer: alignedFace)
                    ])
                    let prediction = try model.prediction(from: input)
                    guard let array = prediction.featureValue(for: "embedding")?.multiArrayValue,
                          array.count == 512 else {
                        throw FaceEmbeddingError.predictionFailed
                    }
                    let embedding = (0..<array.count).map { array[$0].floatValue }
                    continuation.resume(returning: Self.l2Normalized(embedding))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Raw cosine similarity. AdaFace's publisher uses this same score and treats 0.3 as
    /// a loose match boundary; FaceLock defaults higher and requires multi-frame agreement.
    func similarity(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot = 0.0
        var aa = 0.0
        var bb = 0.0
        for (x, y) in zip(a, b) {
            dot += Double(x * y)
            aa += Double(x * x)
            bb += Double(y * y)
        }
        guard aa > 0, bb > 0 else { return -1 }
        return max(-1, min(1, dot / sqrt(aa * bb)))
    }

    private static func alignedFace(from pixelBuffer: CVPixelBuffer) throws -> CVPixelBuffer {
        let request = VNDetectFaceLandmarksRequest()
        let orientation = CGImagePropertyOrientation.leftMirrored
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation)
        try handler.perform([request])

        guard let faces = request.results, !faces.isEmpty else {
            throw FaceEmbeddingError.noFace
        }
        guard faces.count == 1 else { throw FaceEmbeddingError.multipleFaces }
        let face = faces[0]
        guard min(face.boundingBox.width, face.boundingBox.height) >= 0.16 else {
            throw FaceEmbeddingError.faceTooSmall
        }
        guard let landmarks = face.landmarks,
              let leftEyeCenter = landmarkCenter(landmarks.leftEye),
              let rightEyeCenter = landmarkCenter(landmarks.rightEye),
              let mouthCenter = landmarkCenter(landmarks.outerLips) else {
            throw FaceEmbeddingError.landmarksUnavailable
        }

        return try alignedFace(from: pixelBuffer,
                               using: FaceAlignmentGeometry(faceBoundingBox: face.boundingBox,
                                                            leftEyeCenter: leftEyeCenter,
                                                            rightEyeCenter: rightEyeCenter,
                                                            mouthCenter: mouthCenter))
    }

    private static func landmarkCenter(_ region: VNFaceLandmarkRegion2D?) -> CGPoint? {
        guard let points = region?.normalizedPoints, !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) {
            CGPoint(x: $0.x + $1.x, y: $0.y + $1.y)
        }
        return CGPoint(x: sum.x / CGFloat(points.count),
                       y: sum.y / CGFloat(points.count))
    }

    private static func alignedFace(from pixelBuffer: CVPixelBuffer,
                                    using geometry: FaceAlignmentGeometry) throws -> CVPixelBuffer {
        let orientation = CGImagePropertyOrientation.leftMirrored

        let orientedImage = CIImage(cvPixelBuffer: pixelBuffer)
            .oriented(forExifOrientation: Int32(orientation.rawValue))
        let extent = orientedImage.extent

        func imagePoint(_ normalizedPoint: CGPoint) -> CGPoint {
            CGPoint(
                x: extent.minX + (geometry.faceBoundingBox.minX + normalizedPoint.x * geometry.faceBoundingBox.width) * extent.width,
                y: extent.minY + (geometry.faceBoundingBox.minY + normalizedPoint.y * geometry.faceBoundingBox.height) * extent.height
            )
        }

        let eyeA = imagePoint(geometry.leftEyeCenter)
        let eyeB = imagePoint(geometry.rightEyeCenter)
        let mouth = imagePoint(geometry.mouthCenter)

        // Sorting by image x avoids left/right semantic differences in mirrored camera input.
        let eyes = [eyeA, eyeB].sorted { $0.x < $1.x }
        let source = [eyes[0], eyes[1], mouth]

        // ArcFace/AdaFace's standard 112px template is top-origin. Core Image is
        // bottom-origin, so the template y coordinates are flipped here.
        let destination = [
            CGPoint(x: 38.2946, y: 112 - 51.6963),
            CGPoint(x: 73.5318, y: 112 - 51.5014),
            CGPoint(x: 56.1396, y: 112 - 92.2852)
        ]
        guard let transform = affineTransform(from: source, to: destination) else {
            throw FaceEmbeddingError.alignmentFailed
        }

        var output: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         112,
                                         112,
                                         kCVPixelFormatType_32BGRA,
                                         attributes as CFDictionary,
                                         &output)
        guard status == kCVReturnSuccess, let output else {
            throw FaceEmbeddingError.alignmentFailed
        }

        Self.ciContext.render(orientedImage.transformed(by: transform),
                              to: output,
                              bounds: CGRect(x: 0, y: 0, width: 112, height: 112),
                              colorSpace: CGColorSpaceCreateDeviceRGB())
        return output
    }

    /// Exact affine map between two point triangles.
    private static func affineTransform(from source: [CGPoint], to destination: [CGPoint]) -> CGAffineTransform? {
        guard source.count == 3, destination.count == 3 else { return nil }
        let x0 = source[0].x, y0 = source[0].y
        let x1 = source[1].x, y1 = source[1].y
        let x2 = source[2].x, y2 = source[2].y
        let denominator = x0 * (y1 - y2) + x1 * (y2 - y0) + x2 * (y0 - y1)
        guard abs(denominator) > 0.000_001 else { return nil }

        func coefficients(_ q0: CGFloat, _ q1: CGFloat, _ q2: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
            let first = (q0 * (y1 - y2) + q1 * (y2 - y0) + q2 * (y0 - y1)) / denominator
            let second = (q0 * (x2 - x1) + q1 * (x0 - x2) + q2 * (x1 - x0)) / denominator
            let translation = (q0 * (x1 * y2 - x2 * y1)
                               + q1 * (x2 * y0 - x0 * y2)
                               + q2 * (x0 * y1 - x1 * y0)) / denominator
            return (first, second, translation)
        }

        let x = coefficients(destination[0].x, destination[1].x, destination[2].x)
        let y = coefficients(destination[0].y, destination[1].y, destination[2].y)
        return CGAffineTransform(a: x.0, b: y.0, c: x.1, d: y.1, tx: x.2, ty: y.2)
    }

    private static func l2Normalized(_ values: [Float]) -> [Float] {
        let norm = max(sqrt(values.reduce(Float.zero) { $0 + $1 * $1 }), 0.000_001)
        return values.map { $0 / norm }
    }
}

struct FaceProfile: Codable {
    let embeddings: [[Float]]
    let createdAt: Date
    let embeddingKind: String?
    let samplesPerPose: Int?
}

struct FaceMatchDecision {
    let medianScore: Double
    let minimumScore: Double
    let maximumScore: Double
    let passingSamples: Int
    let meanScore: Double
    let standardDeviation: Double
    let passed: Bool
}

enum FaceMatchEvaluator {
    static let requiredSampleCount = 7
    static let requiredPassingSamples = 5
    static let sampleIntervalMilliseconds = 20

    /// Shared by the visible recognition test and the actual locked-screen path.
    /// Five of seven fresh, quality-gated frames must clear the threshold.
    static func decision(scores: [Double], threshold: Double) -> FaceMatchDecision? {
        guard scores.count == requiredSampleCount else { return nil }
        let ordered = scores.sorted()
        let median = ordered[ordered.count / 2]
        let mean = scores.reduce(0, +) / Double(scores.count)
        let variance = scores.reduce(0) { $0 + pow($1 - mean, 2) } / Double(scores.count)
        let passingSamples = scores.filter { $0 >= threshold }.count
        return FaceMatchDecision(medianScore: median,
                                 minimumScore: ordered[0],
                                 maximumScore: ordered[ordered.count - 1],
                                 passingSamples: passingSamples,
                                 meanScore: mean,
                                 standardDeviation: sqrt(variance),
                                 passed: median >= threshold && passingSamples >= requiredPassingSamples)
    }

    /// Returns a positive decision as soon as five observed frames pass. The two
    /// unobserved slots can be treated as failures and the original 5-of-7 rule is
    /// still mathematically satisfied, so this does not weaken the vote threshold.
    static func decisiveEarlyMatch(scores: [Double], threshold: Double) -> FaceMatchDecision? {
        guard scores.count >= requiredPassingSamples,
              scores.count < requiredSampleCount,
              scores.filter({ $0 >= threshold }).count >= requiredPassingSamples else { return nil }
        let ordered = scores.sorted()
        let median = ordered[ordered.count / 2]
        let mean = scores.reduce(0, +) / Double(scores.count)
        let variance = scores.reduce(0) { $0 + pow($1 - mean, 2) } / Double(scores.count)
        guard median >= threshold else { return nil }
        return FaceMatchDecision(medianScore: median,
                                 minimumScore: ordered[0],
                                 maximumScore: ordered[ordered.count - 1],
                                 passingSamples: scores.filter { $0 >= threshold }.count,
                                 meanScore: mean,
                                 standardDeviation: sqrt(variance),
                                 passed: true)
    }
}

@MainActor
final class FaceProfileStore {
    static let shared = FaceProfileStore()
    private let crypto = CryptoService()
    private var cachedProfile: FaceProfile?
    private var cachedCentroid: [Float]?

    private var profileURL: URL {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FaceLock", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Keep v1 public storage isolated from pre-release profiles encrypted by a
        // differently signed build. Users re-enroll once instead of receiving an
        // unexpected login-Keychain password prompt or an undecryptable profile.
        return directory.appendingPathComponent("face-profile-v2.enc")
    }

    var isEnrolled: Bool { FileManager.default.fileExists(atPath: profileURL.path) }
    var isPreparedForLockedSession: Bool { cachedProfile != nil }

    func save(embeddings: [[Float]], samplesPerPose: Int = 1) throws {
        let profile = FaceProfile(embeddings: embeddings,
                                  createdAt: Date(),
                                  embeddingKind: FaceEmbeddingService.embeddingKind,
                                  samplesPerPose: samplesPerPose)
        try persist(profile)
        cachedProfile = profile
        cachedCentroid = Self.normalizedMean(profile.embeddings)
    }

    func load() throws -> FaceProfile {
        if let cachedProfile { return cachedProfile }
        let encrypted = try Data(contentsOf: profileURL)
        let profile = try JSONDecoder().decode(FaceProfile.self, from: crypto.decrypt(encrypted))
        cachedProfile = profile
        cachedCentroid = Self.normalizedMean(profile.embeddings)
        return profile
    }

    /// Loads and decrypts the profile while the user session is unlocked, then rewrites
    /// the already-encrypted blob with after-first-login file protection. The in-memory
    /// profile lets matching proceed after the Keychain and protected files are locked.
    func prepareForLockedSession() throws {
        let profile = try load()
        guard profile.embeddingKind == FaceEmbeddingService.embeddingKind else {
            throw FaceEmbeddingError.outdatedProfile
        }
        try persist(profile)
        cachedProfile = profile
        cachedCentroid = Self.normalizedMean(profile.embeddings)
    }

    private func persist(_ profile: FaceProfile) throws {
        let encoded = try JSONEncoder().encode(profile)
        let encrypted = try crypto.encrypt(encoded)
        try encrypted.write(to: profileURL,
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func delete() throws {
        cachedProfile = nil
        cachedCentroid = nil
        if FileManager.default.fileExists(atPath: profileURL.path) {
            try FileManager.default.removeItem(at: profileURL)
        }
        try crypto.deleteKey()
    }

    func bestSimilarity(for embedding: [Float]) throws -> Double {
        let service = FaceEmbeddingService()
        let profile = try load()
        guard profile.embeddingKind == FaceEmbeddingService.embeddingKind else {
            throw FaceEmbeddingError.outdatedProfile
        }
        let scores = profile.embeddings.map { service.similarity(embedding, $0) }.sorted(by: >)
        guard !scores.isEmpty else { return -1 }
        let galleryCount = min(7, scores.count)
        let galleryScore = scores.prefix(galleryCount).reduce(0, +) / Double(galleryCount)
        let centroid = cachedCentroid ?? Self.normalizedMean(profile.embeddings)
        cachedCentroid = centroid
        let centroidScore = service.similarity(embedding, centroid)
        // The gallery component handles pose variation; the global centroid prevents one
        // unusually similar enrollment view from dominating a stranger comparison.
        return 0.45 * galleryScore + 0.55 * centroidScore
    }

    private static func normalizedMean(_ embeddings: [[Float]]) -> [Float] {
        guard let dimension = embeddings.first?.count, dimension > 0 else { return [] }
        var mean = [Float](repeating: 0, count: dimension)
        var count: Float = 0
        for embedding in embeddings where embedding.count == dimension {
            for index in 0..<dimension { mean[index] += embedding[index] }
            count += 1
        }
        guard count > 0 else { return [] }
        for index in 0..<dimension { mean[index] /= count }
        let norm = max(sqrt(mean.reduce(Float.zero) { $0 + $1 * $1 }), 0.000_001)
        return mean.map { $0 / norm }
    }
}
