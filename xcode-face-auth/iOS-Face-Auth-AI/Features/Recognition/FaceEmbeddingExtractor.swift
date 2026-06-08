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
import ImageIO

/// Extracts face embeddings from the bundled Core ML model.
/// AuraFace is preferred, with MobileFaceNet as a fallback.
@MainActor
class FaceEmbeddingExtractor {

    struct SupportedModel {
        let resourceName: String
        let displayName: String
        let defaultEmbeddingDimension: Int
    }

    static let supportedModels: [SupportedModel] = [
        SupportedModel(resourceName: "AuraFace", displayName: "AuraFace", defaultEmbeddingDimension: 512),
        SupportedModel(resourceName: "MobileFaceNet", displayName: "MobileFaceNet", defaultEmbeddingDimension: 128)
    ]

    enum ModelLoadingState {
        case notLoaded
        case loading
        case loaded
        case failed(Error)
    }

    private(set) var loadingState: ModelLoadingState = .notLoaded
    private var model: MLModel?

    private let inputSize = CGSize(width: 112, height: 112)

    private(set) var embeddingDimension: Int = 512
    private(set) var activeModelName: String?

    init() {
        Task {
            await loadModel()
        }
    }

    func loadModel() async {
        loadingState = .loading
        model = nil
        activeModelName = nil

        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all

            for candidate in Self.supportedModels {
                guard let modelURL = Bundle.main.url(forResource: candidate.resourceName, withExtension: "mlmodelc") else {
                    continue
                }

                let loadedModel = try MLModel(contentsOf: modelURL, configuration: config)
                model = loadedModel
                activeModelName = candidate.displayName

                if let outputDescription = loadedModel.modelDescription.outputDescriptionsByName.values.first,
                   let shape = outputDescription.multiArrayConstraint?.shape {
                    embeddingDimension = shape.last?.intValue ?? candidate.defaultEmbeddingDimension
                } else {
                    embeddingDimension = candidate.defaultEmbeddingDimension
                }

                loadingState = .loaded
                DebugLogger.shared.log(
                    category: .faceAuth,
                    message: "Core ML model loaded",
                    details: "\(candidate.displayName), dim: \(embeddingDimension), computeUnits: all"
                )
                return
            }

            loadingState = .failed(ModelError.modelNotFound)
            DebugLogger.shared.log(
                level: .warning,
                category: .faceAuth,
                message: "No supported model found in bundle",
                details: Self.supportedModels.map(\.resourceName).joined(separator: ", ")
            )
        } catch {
            loadingState = .failed(error)
            DebugLogger.shared.log(
                level: .error,
                category: .faceAuth,
                message: "Core ML model load failed",
                details: error.localizedDescription
            )
        }
    }

    var isModelLoaded: Bool {
        if case .loaded = loadingState { return true }
        return false
    }

    func extractEmbedding(from pixelBuffer: CVPixelBuffer, boundingBox: CGRect) async -> [Float]? {
        guard let model else {
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Embedding extraction failed: model unavailable")
            return nil
        }

        guard let croppedBuffer = cropAndResize(
            pixelBuffer: pixelBuffer,
            boundingBox: boundingBox,
            targetSize: inputSize
        ) else {
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Face crop failed", details: "boundingBox: \(boundingBox)")
            return nil
        }

        do {
            guard let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
                DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Model input name not found")
                return nil
            }

            let inputFeature = try MLFeatureValue(pixelBuffer: croppedBuffer)
            let inputProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: inputFeature])
            let output = try await model.prediction(from: inputProvider)

            guard let outputName = model.modelDescription.outputDescriptionsByName.keys.first,
                  let multiArray = output.featureValue(for: outputName)?.multiArrayValue else {
                DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Model output not found")
                return nil
            }

            let embedding = (0..<multiArray.count).map { Float(truncating: multiArray[$0]) }
            return l2Normalize(embedding)
        } catch {
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Core ML prediction failed", details: error.localizedDescription)
            return nil
        }
    }

    func extractEmbedding(from croppedFaceBuffer: CVPixelBuffer) async -> [Float]? {
        guard let model else { return nil }

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
            DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Core ML prediction failed (cropped)", details: error.localizedDescription)
            return nil
        }
    }

    private func cropAndResize(pixelBuffer: CVPixelBuffer, boundingBox: CGRect, targetSize: CGSize) -> CVPixelBuffer? {
        // Vision detects faces with .leftMirrored in CameraViewController, so crop
        // from an image with the same orientation. Otherwise the model sees a
        // slightly wrong face region and same-person scores drop hard.
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.leftMirrored)
        let imageExtent = ciImage.extent.integral
        let imageWidth = imageExtent.width
        let imageHeight = imageExtent.height

        let rect = VNImageRectForNormalizedRect(
            boundingBox,
            Int(imageWidth),
            Int(imageHeight)
        ).offsetBy(dx: imageExtent.origin.x, dy: imageExtent.origin.y)

        let marginX = rect.width * 0.18
        let marginY = rect.height * 0.25
        let expandedRect = rect.insetBy(dx: -marginX, dy: -marginY)
            .intersection(imageExtent)

        guard expandedRect.width > 0, expandedRect.height > 0 else {
            return nil
        }

        let cropRect = squareCropRect(around: expandedRect, inside: imageExtent)

        let cropped = ciImage.cropped(to: cropRect)
        let translated = cropped.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        let scaleX = targetSize.width / cropRect.width
        let scaleY = targetSize.height / cropRect.height
        let scaled = translated.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return createPixelBuffer(from: scaled, size: targetSize)
    }

    private func squareCropRect(around rect: CGRect, inside bounds: CGRect) -> CGRect {
        let side = min(max(rect.width, rect.height), min(bounds.width, bounds.height))
        let centerX = rect.midX
        let centerY = rect.midY

        var originX = centerX - side / 2
        var originY = centerY - side / 2
        originX = min(max(originX, bounds.minX), bounds.maxX - side)
        originY = min(max(originY, bounds.minY), bounds.maxY - side)

        return CGRect(x: originX, y: originY, width: side, height: side)
    }

    private func resizePixelBuffer(_ pixelBuffer: CVPixelBuffer, to targetSize: CGSize) -> CVPixelBuffer? {
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        let currentWidth = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let currentHeight = CGFloat(CVPixelBufferGetHeight(pixelBuffer))

        let scaleX = targetSize.width / currentWidth
        let scaleY = targetSize.height / currentHeight
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        return createPixelBuffer(from: scaled, size: targetSize)
    }

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

    private func l2Normalize(_ vector: [Float]) -> [Float] {
        let sumOfSquares = vector.reduce(0) { $0 + $1 * $1 }
        let norm = sqrt(sumOfSquares)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}

enum ModelError: LocalizedError {
    case modelNotFound
    case predictionFailed

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            let names = FaceEmbeddingExtractor.supportedModels
                .map { "\($0.resourceName).mlmodelc" }
                .joined(separator: " or ")
            return "Bundled model not found: \(names)"
        case .predictionFailed:
            return "Core ML prediction failed."
        }
    }
}
