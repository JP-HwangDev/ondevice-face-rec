//
//  CameraView.swift
//  FaceAuthApp
//
//  Created by yon on 2026/01/25.
//

import SwiftUI
import AVFoundation
import Combine
import Vision

struct CameraView: UIViewControllerRepresentable {
    var onFaceDetected: (([VNFaceObservation], CVPixelBuffer) -> Void)?
    var onLandmarksDetected: (([VNFaceObservation]) -> Void)?
    var onImageSizeDetected: ((CGSize) -> Void)?

    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.onFaceDetected = onFaceDetected
        controller.onLandmarksDetected = onLandmarksDetected
        controller.onImageSizeDetected = onImageSizeDetected
        return controller
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {
        uiViewController.onFaceDetected = onFaceDetected
        uiViewController.onLandmarksDetected = onLandmarksDetected
        uiViewController.onImageSizeDetected = onImageSizeDetected
    }
}

// 카메라 권한 확인 및 요청을 위한 매니저
@MainActor
class CameraPermissionManager: ObservableObject {
    @Published var permissionGranted = false
    
    func requestPermission() async {
        // 카메라 권한 요청
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        
        switch status {
        case .authorized:
            permissionGranted = true
            
        case .notDetermined:
            // 권한 요청
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionGranted = granted
            
        case .denied, .restricted:
            permissionGranted = false
            
        @unknown default:
            permissionGranted = false
        }
    }
}
