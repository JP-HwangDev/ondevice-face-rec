//
//  FaceRecognitionManager.swift
//  FaceAuthApp
//
//  Created by yon on 2026/02/01.
//

import Foundation
import Combine
import Accelerate
import Vision
import CoreML
import CoreVideo
import UIKit

@MainActor
class FaceRecognitionManager: ObservableObject {
    @Published var detectedMatches: [FaceMatch] = []
    @Published var isProcessing = false
    @Published var isFaceDetected = false
    @Published var faceObservations: [VNFaceObservation] = []
    @Published var lastAttendanceResult: AttendanceResult?
    @Published var cameraImageSize: CGSize = .zero

    enum ModelStatus {
        case notLoaded
        case loaded
        case mockMode
    }

    @Published var modelStatus: ModelStatus = .notLoaded

    struct AttendanceResult: Identifiable {
        let id = UUID()
        let employee: Employee
        let confidence: Float
        let type: AttendanceType
        let alreadyCheckedIn: Bool
        let timestamp: Date
    }

    private let embeddingExtractor = FaceEmbeddingExtractor()
    private var currentPixelBuffer: CVPixelBuffer?

    // AuraFace raw cosine 기준: 본인 0.5~0.8, 타인 0.0~0.3
    private var similarityThreshold: Float {
        let value = UserDefaults.standard.double(forKey: "similarity_threshold")
        return Float(value > 0 ? value : 0.4)
    }

    private let maxMatches = 3
    private var lastProcessTime: Date = .distantPast
    private let processInterval: TimeInterval = 0.3

    var activeModelName: String {
        embeddingExtractor.activeModelName ?? "목업"
    }

    var activeEmbeddingDimension: Int {
        embeddingExtractor.embeddingDimension
    }

    init() {
        Task {
            await checkModelAvailability()
        }
    }

    private func checkModelAvailability() async {
        try? await Task.sleep(for: .milliseconds(500))

        if embeddingExtractor.isModelLoaded {
            modelStatus = .loaded
            DebugLogger.shared.log(
                category: .faceAuth,
                message: "얼굴 모델 로드 성공",
                details: "\(activeModelName), 출력 차원: \(activeEmbeddingDimension)"
            )
        } else {
            modelStatus = .mockMode
            DebugLogger.shared.log(
                level: .warning,
                category: .faceAuth,
                message: "얼굴 모델 없음",
                details: "출석 인식은 비활성화됩니다."
            )
        }
    }

    func processFaceObservations(_ observations: [VNFaceObservation], pixelBuffer: CVPixelBuffer? = nil) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessTime) >= processInterval else { return }
        lastProcessTime = now

        let wasDetected = isFaceDetected
        isFaceDetected = !observations.isEmpty
        faceObservations = observations
        currentPixelBuffer = pixelBuffer

        if isFaceDetected {
            if !wasDetected {
                DebugLogger.shared.log(
                    category: .faceAuth,
                    message: "얼굴 감지 시작: \(observations.count)명",
                    details: "임계값: \(Int(similarityThreshold * 100))%, 등록 사원: \(EmployeeStore.shared.employees.count)명"
                )
            }
            Task {
                await recognizeFace()
            }
        } else {
            if wasDetected {
                DebugLogger.shared.log(category: .faceAuth, message: "얼굴 감지 해제")
            }
            detectedMatches = []
        }
    }

    private func recognizeFace() async {
        isProcessing = true
        defer { isProcessing = false }

        guard modelStatus == .loaded,
              let pixelBuffer = currentPixelBuffer,
              let firstFace = faceObservations.first else {
            detectedMatches = []
            return
        }

        guard let currentVector = await embeddingExtractor.extractEmbedding(
            from: pixelBuffer,
            boundingBox: firstFace.boundingBox
        ) else {
            detectedMatches = []
            DebugLogger.shared.log(level: .warning, category: .faceAuth, message: "임베딩 추출 실패로 인식 중단")
            return
        }

        let employees = EmployeeStore.shared.employees
        let compatibleEmployees = employees.filter {
            $0.isCompatible(withModel: embeddingExtractor.activeModelName, dimension: activeEmbeddingDimension)
        }

        guard !compatibleEmployees.isEmpty else {
            detectedMatches = []
            DebugLogger.shared.log(
                level: .warning,
                category: .faceAuth,
                message: "호환되는 등록 얼굴이 없음",
                details: "현재 모델: \(activeModelName), 차원: \(activeEmbeddingDimension), 전체 사원: \(employees.count)명"
            )
            return
        }

        let incompatibleCount = employees.count - compatibleEmployees.count
        if incompatibleCount > 0 {
            DebugLogger.shared.log(
                level: .warning,
                category: .faceAuth,
                message: "현재 모델과 다른 등록 얼굴이 있음",
                details: "호환: \(compatibleEmployees.count)명, 재등록 필요: \(incompatibleCount)명"
            )
        }

        let allResults = compatibleEmployees.map { employee in
            FaceMatch(employee: employee, confidence: bestSimilarity(current: currentVector, employee: employee))
        }
        .sorted { $0.confidence > $1.confidence }

        let matches = allResults
            .prefix(maxMatches)
            .filter { $0.confidence > similarityThreshold }

        detectedMatches = Array(matches)

        if let top = detectedMatches.first {
            DebugLogger.shared.log(
                category: .faceAuth,
                message: "얼굴 매칭: \(top.employee.name) \(top.confidencePercent)%",
                details: detectedMatches.map { "\($0.employee.name): \($0.confidencePercent)%" }.joined(separator: ", ")
            )
        } else if let best = allResults.first {
            DebugLogger.shared.log(
                category: .faceAuth,
                message: "매칭 결과 없음",
                details: "최고 유사도: \(best.confidencePercent)%, 임계값: \(Int(similarityThreshold * 100))%"
            )
        }
    }

    private func bestSimilarity(current: [Float], employee: Employee) -> Float {
        guard employee.isCompatible(withModel: embeddingExtractor.activeModelName, dimension: current.count) else {
            DebugLogger.shared.log(
                level: .warning,
                category: .faceAuth,
                message: "벡터 차원 또는 모델 불일치: \(employee.name)",
                details: "현재 \(activeModelName) \(current.count)차원 vs 등록 \(employee.embeddingModel) \(employee.faceVector.count)차원"
            )
            return 0
        }

        var best = cosineSimilarity(current, employee.faceVector)
        for vector in employee.faceVectors where vector.count == current.count {
            let similarity = cosineSimilarity(current, vector)
            if similarity > best {
                best = similarity
            }
        }
        return best
    }

    func checkAttendance(for employee: Employee, type: AttendanceType = .checkIn) {
        let match = detectedMatches.first { $0.employee.id == employee.id }
        let confidence = match?.confidence ?? 0
        let alreadyCheckedIn = AttendanceStore.shared.hasCheckedInToday(employeeId: employee.id)

        if !alreadyCheckedIn || type == .checkOut {
            AttendanceStore.shared.record(employee: employee, confidence: confidence, type: type)
        }

        lastAttendanceResult = AttendanceResult(
            employee: employee,
            confidence: confidence,
            type: type,
            alreadyCheckedIn: alreadyCheckedIn && type == .checkIn,
            timestamp: Date()
        )

        let enableHaptic = UserDefaults.standard.object(forKey: "enable_haptic") as? Bool ?? true
        if alreadyCheckedIn && type == .checkIn {
            if enableHaptic {
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
            }
            DebugLogger.shared.log(level: .warning, category: .faceAuth, message: "\(employee.name) 중복 출근 체크", details: "유사도 \(Int(confidence * 100))%")
        } else {
            if enableHaptic {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            DebugLogger.shared.log(category: .faceAuth, message: "\(type.rawValue) 처리 완료: \(employee.name)", details: "부서 \(employee.department), 유사도 \(Int(confidence * 100))%")
        }
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }

        var dot: Float = 0
        var normA: Float = 0
        var normB: Float = 0

        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))

        let denominator = sqrt(normA) * sqrt(normB)
        guard denominator > 0 else { return 0 }

        return max(0, dot / denominator)
    }
}
