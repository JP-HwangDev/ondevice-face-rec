//
//  CameraViewController.swift
//  FaceAuthApp
//
//  Created by yon on 2026/01/25.
//

import UIKit
import AVFoundation
import Vision

class CameraViewController: UIViewController {
    var captureSession: AVCaptureSession?
    var previewLayer: AVCaptureVideoPreviewLayer?

    // Vision 얼굴 감지용
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let videoDataOutputQueue = DispatchQueue(label: "VideoDataOutput", qos: .userInitiated)

    // 얼굴 감지 콜백 (observations + 원본 pixelBuffer 함께 전달)
    // FaceRectangles rev3 결과 → yaw/pitch 포함
    var onFaceDetected: (([VNFaceObservation], CVPixelBuffer) -> Void)?

    // 랜드마크 감지 콜백 (landmarks 포함된 observations)
    // bbox 그리기 등에 사용
    var onLandmarksDetected: (([VNFaceObservation]) -> Void)?

    // 카메라 이미지 크기 콜백
    var onImageSizeDetected: ((CGSize) -> Void)?
    private var hasReportedImageSize = false

    // 프레임 스킵 (과도한 처리 방지)
    private var frameCounter = 0
    private let processEveryNFrames = 3  // 3프레임마다 1회 처리

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func setupCamera() {
        captureSession = AVCaptureSession()
        guard let captureSession = captureSession else { return }

        // 세션 프리셋 설정
        captureSession.sessionPreset = .high

        // 전면 카메라 사용
        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else {
            DebugLogger.shared.log(level: .error, category: .general, message: "전면 카메라를 찾을 수 없음")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: frontCamera)

            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }

            // 비디오 데이터 출력 설정 (Vision 분석용)
            videoDataOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
            ]
            videoDataOutput.setSampleBufferDelegate(self, queue: videoDataOutputQueue)
            videoDataOutput.alwaysDiscardsLateVideoFrames = true

            if captureSession.canAddOutput(videoDataOutput) {
                captureSession.addOutput(videoDataOutput)
            }

            // 비디오 연결 설정
            if let connection = videoDataOutput.connection(with: .video) {
                connection.isEnabled = true
                // Vision이 .leftMirrored orientation으로 미러링을 직접 처리하므로
                // 픽셀버퍼에 미러링 적용 시 이중 미러링으로 Y축 반전 버그 발생 → 설정 안 함
            }

            // 프리뷰 레이어 설정
            previewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
            previewLayer?.videoGravity = .resizeAspectFill
            previewLayer?.frame = view.bounds

            if let previewLayer = previewLayer {
                view.layer.addSublayer(previewLayer)
            }

            // 카메라 시작 (백그라운드 스레드에서 실행)
            DispatchQueue.global(qos: .userInitiated).async {
                captureSession.startRunning()
                DispatchQueue.main.async {
                    DebugLogger.shared.log(category: .general, message: "카메라 세션 시작", details: "프리셋: high, 전면 카메라, 미러링: on")
                }
            }

        } catch {
            DebugLogger.shared.log(level: .error, category: .general, message: "카메라 설정 실패", details: error.localizedDescription)
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.stopRunning()
            DispatchQueue.main.async {
                DebugLogger.shared.log(category: .general, message: "카메라 세션 중지")
            }
        }
    }
}

// MARK: - Vision 얼굴 감지

extension CameraViewController: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // 프레임 스킵
        frameCounter += 1
        guard frameCounter % processEveryNFrames == 0 else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // 카메라 이미지 크기 보고 (최초 1회)
        if !hasReportedImageSize {
            let imageWidth = CVPixelBufferGetWidth(pixelBuffer)
            let imageHeight = CVPixelBufferGetHeight(pixelBuffer)
            let imageSize = CGSize(width: imageWidth, height: imageHeight)
            hasReportedImageSize = true
            DispatchQueue.main.async { [weak self] in
                self?.onImageSizeDetected?(imageSize)
            }
        }

        // 1) FaceRectangles rev3: yaw/pitch 제공 (등록 포즈 매칭에 필수)
        let faceRectsRequest = VNDetectFaceRectanglesRequest()
        faceRectsRequest.revision = VNDetectFaceRectanglesRequestRevision3

        // 2) FaceLandmarks: 턱선/눈썹 등 랜드마크 제공 (정확한 bbox 그리기용)
        let faceLandmarksRequest = VNDetectFaceLandmarksRequest()
        faceLandmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3

        let imageRequestHandler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,
            options: [:]
        )

        do {
            try imageRequestHandler.perform([faceRectsRequest, faceLandmarksRequest])

            let rectObservations = faceRectsRequest.results ?? []
            let landmarkObservations = faceLandmarksRequest.results ?? []

            DispatchQueue.main.async { [weak self] in
                // yaw/pitch가 있는 rect observations → 인식/등록용
                self?.onFaceDetected?(rectObservations, pixelBuffer)
                // landmarks가 있는 observations → bbox 그리기용
                if !landmarkObservations.isEmpty {
                    self?.onLandmarksDetected?(landmarkObservations)
                }
            }
        } catch {
            DispatchQueue.main.async {
                DebugLogger.shared.log(level: .error, category: .faceAuth, message: "Vision 요청 실행 오류", details: error.localizedDescription)
            }
        }
    }
}
