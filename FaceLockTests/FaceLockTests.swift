import XCTest
@testable import FaceLock

final class FaceLockTests: XCTestCase {
    func testPublicBuildUsesVersionedKeychainNamespace() {
        XCTAssertEqual(KeychainStore.service, "io.github.arjun1223.FaceLock.credentials.v3")
        XCTAssertNotEqual(KeychainStore.service, "com.facelock.local.credentials")
        XCTAssertNotEqual(KeychainStore.service, "io.github.arjun1223.FaceLock.credentials.v2")
    }

    func testCosineSimilarity() {
        let service = FaceEmbeddingService()
        XCTAssertEqual(service.similarity([1, 0, 0], [1, 0, 0]), 1, accuracy: 0.0001)
        XCTAssertEqual(service.similarity([1, 0, 0], [0, 1, 0]), 0, accuracy: 0.0001)
        XCTAssertEqual(service.similarity([1, 0, 0], [-1, 0, 0]), -1, accuracy: 0.0001)
    }

    func testBundledIR101ModelLoads() {
        XCTAssertEqual(FaceEmbeddingService.modelParameterCount, 65_150_912)
        XCTAssertTrue(FaceEmbeddingService.isBundledModelAvailable)
    }

    func testPoseChallenges() {
        XCTAssertTrue(RequiredPose.center.isSatisfied(by: FacePose(faceDetected: true)))
        XCTAssertTrue(RequiredPose.right.isSatisfied(by: FacePose(yawDegrees: 20, faceDetected: true)))
        XCTAssertFalse(RequiredPose.right.isSatisfied(by: FacePose(yawDegrees: 5, faceDetected: true)))
    }

    func testPassiveLivenessNeedsSeveralFramesAndMovement() {
        var stillChallenge = LivenessChallenge()
        for _ in 0..<6 {
            XCTAssertFalse(stillChallenge.verify(FacePose(faceDetected: true)))
        }

        var challenge = LivenessChallenge()
        for index in 0..<4 {
            XCTAssertFalse(challenge.verify(FacePose(yawDegrees: Double(index) * 0.05,
                                                      faceDetected: true)))
        }
        XCTAssertTrue(challenge.verify(FacePose(yawDegrees: 0.5, faceDetected: true)))

        var landmarkChallenge = LivenessChallenge()
        for index in 0..<4 {
            XCTAssertFalse(landmarkChallenge.verify(FacePose(noseX: 0.5 + Double(index) * 0.001,
                                                              faceDetected: true)))
        }
        XCTAssertTrue(landmarkChallenge.verify(FacePose(noseX: 0.51, faceDetected: true)))
    }

    func testFaceMatchDecisionRequiresSevenSamplesAndFiveVotes() {
        XCTAssertNil(FaceMatchEvaluator.decision(scores: [0.9], threshold: 0.45))

        let oneLuckyFrame = FaceMatchEvaluator.decision(scores: [0.2, 0.22, 0.25, 0.3, 0.32, 0.35, 0.9],
                                                        threshold: 0.45)
        XCTAssertEqual(oneLuckyFrame?.passingSamples, 1)
        XCTAssertFalse(oneLuckyFrame?.passed ?? true)

        let onlyFourVotes = FaceMatchEvaluator.decision(scores: [0.2, 0.3, 0.4, 0.46, 0.5, 0.52, 0.54],
                                                        threshold: 0.45)
        XCTAssertEqual(onlyFourVotes?.passingSamples, 4)
        XCTAssertFalse(onlyFourVotes?.passed ?? true)

        let fiveVotes = FaceMatchEvaluator.decision(scores: [0.2, 0.3, 0.46, 0.48, 0.5, 0.52, 0.54],
                                                    threshold: 0.45)
        XCTAssertEqual(fiveVotes?.passingSamples, 5)
        XCTAssertTrue(fiveVotes?.passed ?? false)
    }

    func testFastMatchCanOnlyFinishAfterFivePassingFrames() {
        XCTAssertNil(FaceMatchEvaluator.decisiveEarlyMatch(scores: [0.9, 0.9, 0.9, 0.9],
                                                            threshold: 0.45))
        XCTAssertNil(FaceMatchEvaluator.decisiveEarlyMatch(scores: [0.9, 0.9, 0.9, 0.9, 0.2],
                                                            threshold: 0.45))
        let secured = FaceMatchEvaluator.decisiveEarlyMatch(scores: [0.56, 0.58, 0.59, 0.61, 0.63],
                                                             threshold: 0.45)
        XCTAssertEqual(secured?.passingSamples, 5)
        XCTAssertTrue(secured?.passed ?? false)
    }

    func testRecognitionQualityGateRejectsWeakOrMultipleFaces() {
        XCTAssertFalse(FacePose(captureQuality: 0.1, faceDetected: true).isRecognitionReady)
        XCTAssertFalse(FacePose(faceCount: 2, faceDetected: true).isRecognitionReady)
        XCTAssertFalse(FacePose(faceSize: 0.1, faceDetected: true).isRecognitionReady)
        XCTAssertTrue(FacePose(captureQuality: 0.8, faceSize: 0.4, confidence: 1,
                               faceCount: 1, faceDetected: true).isRecognitionReady)
    }

    func testRecognitionAllowsFaceAngleThrough125Degrees() {
        let angled = FacePose(yawDegrees: 35, captureQuality: 0.11,
                              eyeContactScore: 0.11, eyeOpenness: 0.2,
                              faceDetected: true)
        XCTAssertEqual(angled.facingAngleDegrees, 125, accuracy: 0.001)
        XCTAssertTrue(angled.isWithinRecognitionAngle)
        XCTAssertTrue(angled.isRecognitionReady)
        XCTAssertTrue(angled.isLookingAtCamera)

        XCTAssertFalse(FacePose(yawDegrees: 36, captureQuality: 1,
                                eyeContactScore: 1, faceDetected: true).isRecognitionReady)
        XCTAssertFalse(FacePose(yawDegrees: 36, captureQuality: 1,
                                eyeContactScore: 1, faceDetected: true).isLookingAtCamera)

        // The centered gate stays strict; the tolerance applies only as Vision
        // measures a real head turn inside the supported range.
        XCTAssertFalse(FacePose(yawDegrees: 0, captureQuality: 0.11,
                                eyeContactScore: 0.11, faceDetected: true).isRecognitionReady)
        XCTAssertFalse(FacePose(yawDegrees: 0, captureQuality: 1,
                                eyeContactScore: 0.11, faceDetected: true).isLookingAtCamera)
    }

    func testEyeAttentionRequiresCenteredOpenEyesAndFinalAttention() {
        XCTAssertFalse(FacePose(eyeContactScore: 0.1, faceDetected: true).isLookingAtCamera)
        XCTAssertFalse(FacePose(eyeOpenness: 0.05, faceDetected: true).isLookingAtCamera)
        XCTAssertFalse(FacePose(pupilsDetected: false, faceDetected: true).isLookingAtCamera)
        XCTAssertTrue(FacePose(eyeContactScore: 0.8, eyeOpenness: 0.2,
                               pupilsDetected: true, faceDetected: true).isLookingAtCamera)

        XCTAssertTrue(EyeAttentionEvaluator.passed(samples: [true, false, true, true, false, true, true]))
        XCTAssertFalse(EyeAttentionEvaluator.passed(samples: [true, true, true, true, true, true, false]))
        XCTAssertFalse(EyeAttentionEvaluator.passed(samples: [true, false, false, true, false, true, true]))
    }
}
