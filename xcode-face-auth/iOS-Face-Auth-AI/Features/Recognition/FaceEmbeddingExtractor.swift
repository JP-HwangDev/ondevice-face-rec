//
//  FaceEmbeddingExtractor.swift
//  FaceAuthApp
//
//  Created by yon on 2026/02/15.
//

import Foundation
import CoreML
import Vision
import CoreImage

/// AuraFace Core ML 모델을 사용한 얼굴 임베딩 추출
@MainActor
class FaceEmbeddingExtractor {

    /// 모델 로드 상태
    enum ModelLoadingState {
        case notLoaded
        case loading
        case loaded
        case failed(Error)
    }

    private(set) var loadingState: ModelLoadingState = .notLoaded
    private var model: MLModel?

    /// 입력 이미지 크기 (AuraFace 표준)
    private let inputSize = CGSize(width: 112, height: 112)

    /// 출력 벡터 차원 (AuraFace: 512)
    private(set) var embeddingDimension: Int = 512

    init() {
        Task {
            await loadModel()
        }
    }

    /// Core ML 모델 로드
    func loadModel() async {
        loadingState = .loading

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all  // CPU + GPU + ANE 자동 선택 (최적 성능)

            // 번들에서 AuraFace.mlmodelc 찾기
            if let modelURL = Bundle.main.url(forResource: "AuraFace", withExtension: "mlmodelc") {
                model = try MLModel(contentsOf: modelURL, configuration: config)

                // 출력 차원 확인
                if let outputDescription = model?.modelDescription.outputDescriptionsByName.values.first,
                   let shape = outputDescription.multiArrayConstraint?.shape {
                    embeddingDimension = shape.last?.intValue ?? 512
                }

                loadingState = .loaded
                DebugLogger.shared.log(category: .faceAuth, message: "Core ML 모델 로드 성공", details: "AuraFace, 출력 차원: \(embeddingDimension), computeUnits: all")
            } else {
                loadingState = .failed(ModelError.modelNotFound)
                DebugLogger.shared.log(level: .warning, category: .faceAuth, message: "AuraFace.mlmodelc를 번들에서 찾을 수 없음")
            }
        } catch {
            loadingState = .failed(error)
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Core ML 모델 로드 실패", details: error.localizedDescription)
        }
    }

    /// 모델 로드 여부
    var isModelLoaded: Bool {
        if case .loaded = loadingState { return true }
        return false
    }

    // MARK: - 임베딩 추출

    /// 카메라 프레임(CVPixelBuffer)과 얼굴 영역(boundingBox)에서 임베딩 벡터 추출
    func extractEmbedding(from pixelBuffer: CVPixelBuffer, boundingBox: CGRect) async -> [Float]? {
        guard let model = model else {
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "임베딩 추출 실패: 모델 미로드")
            return nil
        }

        // 1. 얼굴 영역 크롭 및 리사이즈
        guard let croppedBuffer = cropAndResize(
            pixelBuffer: pixelBuffer,
            boundingBox: boundingBox,
            targetSize: inputSize
        ) else {
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "얼굴 크롭 실패", details: "boundingBox: \(boundingBox)")
            return nil
        }

        // 2. Core ML 추론
        do {
            guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
                DebugLogger.shared.log(level: .error, category: .faceAuth, message: "모델 입력 이름을 찾을 수 없음")
                return nil
            }

            let inputFeature = try MLFeatureValue(pixelBuffer: croppedBuffer)
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: inputFeature])
            let output = try await model.prediction(from: inputProvider)

            guard let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
                  let multiArray = output.featureValue(for: outputName)?.multiArrayValue else {
                DebugLogger.shared.log(level: .error, category: .faceAuth, message: "모델 출력을 찾을 수 없음")
                return nil
            }

            // MLMultiArray → [Float] 변환
            let embedding = (0..<multiArray.count).map { Float(truncating: multiArray[$0]) }

            // L2 정규화
            return l2Normalize(embedding)

        } catch {
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Core ML 추론 실패", details: error.localizedDescription)
            return nil
        }
    }

    /// 전체 이미지에서 직접 임베딩 추출 (얼굴 영역이 이미 크롭된 경우)
    func extractEmbedding(from croppedFaceBuffer: CVPixelBuffer) async -> [Float]? {
        guard let model = model else { return nil }

        guard let resizedBuffer = resizePixelBuffer(croppedFaceBuffer, to: inputSize) else {
            return nil
        }

        do {
            guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
                return nil
            }

            let inputFeature = try MLFeatureValue(pixelBuffer: resizedBuffer)
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: inputFeature])
            let output = try await model.prediction(from: inputProvider)

            guard let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
                  let multiArray = output.featureValue(for: outputName)?.multiArrayValue else {
                return nil
            }

            let embedding = (0..<multiArray.count).map { Float(truncating: multiArray[$0]) }
            return l2Normalize(embedding)
        } catch {
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Core ML 추론 실패 (크롭)", details: error.localizedDescription)
            return nil
        }
    }

    // MARK: - 이미지 전처리

    /// 얼굴 영역 크롭 및 리사이즈
    private func cropAndResize(pixelBuffer: CVPixelBuffer, boundingBox: CGRect, targetSize: CGSize) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let imageWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let imageHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        // Vision의 정규화된 좌표(0~1, 좌하단 기준) → 실제 픽셀 좌표 변환
        let rect = VNImageRectForNormalizedRect(
            boundingBox,
            Int(imageWidth),
            Int(imageHeight)
        )

        // 얼굴 전체를 포함하도록 충분한 마진 추가
        // 가로: 20% (볼 포함), 세로: 30% (이마+턱 포함)
        let marginX = rect.width * 0.2
        let marginY = rect.height * 0.3
        let expandedRect = rect.insetBy(dx: -marginX, dy: -marginY)
            .intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))

        // 크롭
        let cropped = ciImage.cropped(to: expandedRect)

        // 원점 이동
        let translated = cropped.transformed(by: CGAffineTransform(translationX: -expandedRect.origin.x, y: -expandedRect.origin.y))

        // 리사이즈
        let scaleX = targetSize.width / expandedRect.width
        let scaleY = targetSize.height / expandedRect.height
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return createPixelBuffer(from: scaled, size: targetSize)
    }

    /// CVPixelBuffer 리사이즈
    private func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer, to targetSize: CGSize) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let currentWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let currentHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let scaleX = targetSize.width / currentWidth
        let scaleY = targetSize.height / currentHeight
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return createPixelBuffer(from: scaled, size: targetSize)
    }

    /// CIImage → CVPixelBuffer 변환
    private func createPixelBuffer(from ciImage: CIImage, size: CGSize) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]

        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            Int(size.width),
            Int(size.height),
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pixelBuffer
        )

        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            return nil
        }

        let context = CIContext()
        context.render(ciImage, to: buffer)

        return buffer
    }

    // MARK: - 벡터 정규화

    /// L2 정규화 (벡터 크기를 1로 만듦)
    private func l2Normalize(_ vector: [Float]) -> [Float] {
        let sumOfSquares = vector.reduce(0) { $0 + $1 * $1 }
        let norm = sqrt(sumOfSquares)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

// MARK: - 에러 타입

enum ModelError: LocalizedError {
    case modelNotFound
    case predictionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "AuraFace.mlmodelc 파일을 찾을 수 없습니다. 번들에 모델을 추가해주세요."
        case .predictionFailed:
            return "Core ML 추론에 실패했습니다."
        }
    }
}
