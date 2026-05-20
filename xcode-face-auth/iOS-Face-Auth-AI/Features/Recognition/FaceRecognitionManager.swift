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

/// 얼굴 인식 처리 (Vision + Core ML AuraFace + 출석 기록)
@MainActor
class FaceRecognitionManager: ObservableObject {
    @Published var detectedMatches: [FaceMatch] = []
    @Published var isProcessing = false
    @Published var isFaceDetected = false
    @Published var faceObservations: [VNFaceObservation] = []
    @Published var lastAttendanceResult: AttendanceResult?
    @Published var cameraImageSize: CGSize = .zero

    /// Core ML 모델 로드 상태
    enum ModelStatus {
        case notLoaded
        case loaded
        case mockMode
    }
    @Published var modelStatus: ModelStatus = .notLoaded

    /// 출석 체크 결과
    struct AttendanceResult: Identifiable {
        let id = UUID()
        let employee: Employee
        let confidence: Float
        let type: AttendanceType
        let alreadyCheckedIn: Bool
        let timestamp: Date
    }

    /// 얼굴 임베딩 추출기 (Core ML)
    private let embeddingExtractor = FaceEmbeddingExtractor()

    /// 현재 처리 중인 픽셀 버퍼
    private var currentPixelBuffer: CVPixelBuffer?

    /// 최소 유사도 임계값 (설정에서 조절)
    private var similarityThreshold: Float {
        let value = UserDefaults.standard.double(forKey: "similarity_threshold")
        return Float(value > 0 ? value : 0.6)
    }

    /// 최대 매칭 결과 수
    private let maxMatches = 3

    /// 디바운스 (과도한 처리 방지)
    private var lastProcessTime: Date = .distantPast
    private let processInterval: TimeInterval = 0.3

    init() {
        Task {
            await checkModelAvailability()
        }
    }

    /// .mlmodel 파일이 번들에 있는지 확인
    private func checkModelAvailability() async {
        try? await Task.sleep(for: .milliseconds(500))

        if embeddingExtractor.isModelLoaded {
            modelStatus = .loaded
            DebugLogger.shared.log(category: .faceAuth, message: "AuraFace 모델 로드 성공", details: "출력 차원: \(embeddingExtractor.embeddingDimension)")
        } else {
            modelStatus = .mockMode
            DebugLogger.shared.log(level: .warning, category: .faceAuth, message: "AuraFace 모델 없음 — 목업 모드로 동작")
        }
    }

    // MARK: - 얼굴 처리 파이프라인

    /// Vision에서 얼굴 감지 시 호출
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
                DebugLogger.shared.log(category: .faceAuth, message: "얼굴 감지 시작: \(observations.count)명", details: "임계값: \(Int(similarityThreshold * 100))%, 등록 사원: \(EmployeeStore.shared.employees.count)명")
            }
            Task {
                await recognizeFace()
            }
        } else {
            if wasDetected {
                DebugLogger.shared.log(category: .faceAuth, message: "얼굴 감지 해제 — 카메라에서 사라짐")
            }
            detectedMatches = []
        }
    }

    /// 얼굴 인식 (Core ML 또는 목업)
    private func recognizeFace() async {
        isProcessing = true
        defer { isProcessing = false }

        var currentVector: [Float]?

        // 실제 모델이 로드되었고 픽셀버퍼가 있는 경우
        if modelStatus == .loaded,
           let pixelBuffer = currentPixelBuffer,
           let firstFace = faceObservations.first {

            currentVector = await embeddingExtractor.extractEmbedding(
                from: pixelBuffer,
                boundingBox: firstFace.boundingBox
            )

            if let vector = currentVector {
                DebugLogger.shared.log(category: .faceAuth, message: "Core ML 임베딩 추출 성공: \(vector.count)차원")
            }
        }

        // 모델이 없거나 추출 실패 시 목업 벡터 사용
        if currentVector == nil {
            currentVector = generateRandomVector()
            DebugLogger.shared.log(level: .warning, category: .faceAuth, message: "목업 벡터 사용 (모델 미로드 또는 추출 실패)")
        }

        guard let vector = currentVector else { return }

        // 등록된 사원들과 유사도 비교
        let employees = EmployeeStore.shared.employees

        let allResults = employees.map { employee in
            let similarity = bestSimilarity(current: vector, employee: employee)
            return FaceMatch(employee: employee, confidence: similarity)
        }
        .sorted { $0.confidence > $1.confidence }

        let matches = allResults
            .prefix(maxMatches)
            .filter { $0.confidence > similarityThreshold }

        detectedMatches = Array(matches)

        // 임계값에 의해 필터링된 결과가 있으면 로그
        let filteredOut = allResults.prefix(maxMatches).filter { $0.confidence <= similarityThreshold }
        if !filteredOut.isEmpty && matches.isEmpty {
            DebugLogger.shared.log(category: .faceAuth, message: "매칭 결과 없음 (임계값 미달)", details: "최고 유사도: \(Int((allResults.first?.confidence ?? 0) * 100))%, 임계값: \(Int(similarityThreshold * 100))%")
        }

        if let top = detectedMatches.first {
            DebugLogger.shared.log(
                category: .faceAuth,
                message: "얼굴 매칭: \(top.employee.name) \(top.confidencePercent)%",
                details: detectedMatches.map { "\($0.employee.name): \($0.confidencePercent)%" }.joined(separator: ", ")
            )
        }
    }

    /// 등록된 멀티 벡터 중 가장 높은 유사도를 반환
    private func bestSimilarity(current: [Float], employee: Employee) -> Float {
        let adjustedCurrent = adjustVectorDimension(current, to: employee.faceVector.count)

        // 평균 벡터와의 유사도
        var best = cosineSimilarity(adjustedCurrent, employee.faceVector)

        // 각 각도별 벡터와도 비교하여 최대값 사용
        for vec in employee.faceVectors {
            let adjustedVec = adjustVectorDimension(vec, to: adjustedCurrent.count)
            let sim = cosineSimilarity(adjustedCurrent, adjustedVec)
            if sim > best {
                best = sim
            }
        }
        return best
    }

    /// 벡터 차원 조정
    private func adjustVectorDimension(_ vector: [Float], to targetDim: Int) -> [Float] {
        if vector.count == targetDim {
            return vector
        } else if vector.count < targetDim {
            return vector + [Float](repeating: 0, count: targetDim - vector.count)
        } else {
            return Array(vector.prefix(targetDim))
        }
    }

    // MARK: - 출석 체크

    /// 출석 체크 (선택된 사원) + 햅틱 피드백
    func checkAttendance(for employee: Employee, type: AttendanceType = .checkIn) {
        let match = detectedMatches.first { $0.employee.id == employee.id }
        let confidence = match?.confidence ?? 0

        // 이미 오늘 출근했는지 확인
        let alreadyCheckedIn = AttendanceStore.shared.hasCheckedInToday(employeeId: employee.id)

        if !alreadyCheckedIn || type == .checkOut {
            // 출석 기록 저장
            AttendanceStore.shared.record(employee: employee, confidence: confidence, type: type)
        }

        // 결과 업데이트
        lastAttendanceResult = AttendanceResult(
            employee: employee,
            confidence: confidence,
            type: type,
            alreadyCheckedIn: alreadyCheckedIn && type == .checkIn,
            timestamp: Date()
        )

        // 햅틱 피드백 (설정에서 조절)
        let enableHaptic = UserDefaults.standard.object(forKey: "enable_haptic") as? Bool ?? true
        if alreadyCheckedIn && type == .checkIn {
            if enableHaptic { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
            DebugLogger.shared.log(level: .warning, category: .faceAuth, message: "\(employee.name) 이미 출근 체크됨 (중복)", details: "유사도: \(Int(confidence * 100))%")
        } else {
            if enableHaptic { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            DebugLogger.shared.log(category: .faceAuth, message: "\(type.rawValue) 처리 완료: \(employee.name)", details: "부서: \(employee.department), 유사도: \(Int(confidence * 100))%")
        }
    }

    // MARK: - 벡터 유사도 계산 (Accelerate Framework)

    /// 랜덤 벡터 생성 - 목업 모드에서 사용
    private func generateRandomVector() -> [Float] {
        let dim = embeddingExtractor.embeddingDimension
        return (0..<dim).map { _ in Float.random(in: -1...1) }
    }

    /// 코사인 유사도 (Accelerate 사용으로 고속 계산)
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

        let similarity = dot / denominator
        return max(0, (similarity + 1) / 2)  // -1~1 → 0~1 변환
    }
}
