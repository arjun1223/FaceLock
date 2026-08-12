import Foundation

enum RequiredPose: String, CaseIterable, Identifiable {
    case center, left, right, up, down, tiltLeft, tiltRight
    var id: String { rawValue }
    var prompt: String {
        switch self {
        case .center: return "Look straight ahead"
        case .left: return "Turn your head left"
        case .right: return "Turn your head right"
        case .up: return "Look up"
        case .down: return "Look down"
        case .tiltLeft: return "Tilt your head left"
        case .tiltRight: return "Tilt your head right"
        }
    }

    func isSatisfied(by pose: FacePose) -> Bool {
        guard pose.faceDetected else { return false }
        switch self {
        case .center: return abs(pose.yawDegrees) < 14 && abs(pose.pitchDegrees) < 14 && abs(pose.rollDegrees) < 14
        case .left: return pose.yawDegrees < -12
        case .right: return pose.yawDegrees > 12
        case .up: return pose.pitchDegrees > 8
        case .down: return pose.pitchDegrees < -8
        case .tiltLeft: return pose.rollDegrees < -10
        case .tiltRight: return pose.rollDegrees > 10
        }
    }
}

struct LivenessChallenge {
    private var samples: [FacePose] = []
    private let windowSize = 12
    private let minimumSamples = 5
    private let angularMovementThresholdDegrees = 0.35
    private let landmarkMovementThreshold = 0.006

    /// Passive movement gate adapted from HasBrain/FaceUnlock. Natural micro-movement
    /// across a short frame window is enough; no invisible random-direction prompt.
    mutating func verify(_ pose: FacePose) -> Bool {
        guard pose.isRecognitionReady else {
            samples.removeAll(keepingCapacity: true)
            return false
        }
        samples.append(pose)
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        guard samples.count >= minimumSamples else { return false }

        let yawValues = samples.map(\.yawDegrees)
        let pitchValues = samples.map(\.pitchDegrees)
        let rollValues = samples.map(\.rollDegrees)
        let noseXValues = samples.map(\.noseX)
        let noseYValues = samples.map(\.noseY)
        guard let yawMinimum = yawValues.min(), let yawMaximum = yawValues.max(),
              let pitchMinimum = pitchValues.min(), let pitchMaximum = pitchValues.max(),
              let rollMinimum = rollValues.min(), let rollMaximum = rollValues.max(),
              let noseXMinimum = noseXValues.min(), let noseXMaximum = noseXValues.max(),
              let noseYMinimum = noseYValues.min(), let noseYMaximum = noseYValues.max() else { return false }
        return yawMaximum - yawMinimum >= angularMovementThresholdDegrees
            || pitchMaximum - pitchMinimum >= angularMovementThresholdDegrees
            || rollMaximum - rollMinimum >= angularMovementThresholdDegrees
            || noseXMaximum - noseXMinimum >= landmarkMovementThreshold
            || noseYMaximum - noseYMinimum >= landmarkMovementThreshold
    }
}

enum EyeAttentionEvaluator {
    static let requiredPassingSamples = 5

    /// Tolerates two noisy pupil observations, but the final sampled frame must show
    /// attention so FaceLock never submits after the person has looked away.
    static func passed(samples: [Bool]) -> Bool {
        guard samples.count == FaceMatchEvaluator.requiredSampleCount,
              samples.last == true else { return false }
        return samples.filter { $0 }.count >= requiredPassingSamples
    }

    static func passedEarly(samples: [Bool]) -> Bool {
        guard samples.count >= requiredPassingSamples,
              samples.count < FaceMatchEvaluator.requiredSampleCount,
              samples.last == true else { return false }
        return samples.filter { $0 }.count >= requiredPassingSamples
    }
}
