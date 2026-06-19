import Foundation
@preconcurrency import Vision
@preconcurrency import AVFoundation
import Combine
import SwiftUI
@preconcurrency import CoreML
@preconcurrency import CoreVideo
import CoreImage
import Accelerate

struct SendablePixelBuffer: @unchecked Sendable {
    let buffer: CVPixelBuffer
}

// MARK: - Optimized Camera Manager
class CameraManager: NSObject, ObservableObject {
    @Published var currentBuffer: CVPixelBuffer?
    @Published var isAuthorized = false
    @Published var rotationAngle: CGFloat = 90
    @Published var bufferSize: CGSize = .zero
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.queue", qos: .userInteractive)

    private var frameSkipCounter = 0
    private let frameSkipInterval = 3 // Every 3rd frame — reduces CPU without visible lag

    override init() {
        super.init()
        // Pre-configure session early so camera appears instantly when view opens
        checkPermission()
    }

    private func checkPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            self.isAuthorized = true
            setupSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                if granted {
                    DispatchQueue.main.async {
                        self.isAuthorized = true
                        self.setupSession()
                        self.start()
                    }
                }
            }
        default: self.isAuthorized = false
        }
        
        // Setup orientation tracking
        NotificationCenter.default.addObserver(self, selector: #selector(updateOrientation), name: UIDevice.orientationDidChangeNotification, object: nil)
        updateOrientation()
    }

    @objc private func updateOrientation() {
        let newAngle: CGFloat
        switch UIDevice.current.orientation {
        case .portrait: newAngle = 90
        case .portraitUpsideDown: newAngle = 270
        case .landscapeLeft: newAngle = 180  // swap for front camera
        case .landscapeRight: newAngle = 0   // swap for front camera
        default: return
        }
        if rotationAngle != newAngle {
            rotationAngle = newAngle
            videoOutput.connection(with: .video)?.videoRotationAngle = newAngle
        }
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .hd1280x720
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let input = try? AVCaptureDeviceInput(device: device) else { return }

        // Optimize camera settings
        do {
            try device.lockForConfiguration()
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.unlockForConfiguration()
        } catch { }

        if session.canAddInput(input) { session.addInput(input) }
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if let connection = videoOutput.connection(with: .video) {
            connection.videoRotationAngle = 90
            connection.isVideoMirrored = true
        }
        
        NotificationCenter.default.addObserver(self, selector: #selector(sessionRuntimeError), name: AVCaptureSession.runtimeErrorNotification, object: session)
        
        session.commitConfiguration()
    }
    
    @objc func sessionRuntimeError(notification: NSNotification) {
        guard let error = notification.userInfo?[AVCaptureSessionErrorKey] as? AVError else { return }
        print("Camera runtime error: \(error)")
        // Try to restart if it's not a serious error
        if error.code == .mediaServicesWereReset {
            DispatchQueue.global(qos: .userInitiated).async {
                if !self.session.isRunning {
                    self.session.startRunning()
                }
            }
        } else {
            // Retry anyway
            DispatchQueue.global(qos: .userInitiated).async {
                self.session.startRunning()
            }
        }
    }

    func start() {
        guard isAuthorized else { return }
        if !session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.startRunning() }
        }
    }

    func stop() {
        if session.isRunning {
            DispatchQueue.global(qos: .userInitiated).async { self.session.stopRunning() }
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frameSkipCounter += 1
        guard frameSkipCounter >= frameSkipInterval else { return }
        frameSkipCounter = 0

        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let size = CGSize(width: CGFloat(width), height: CGFloat(height))
        
        DispatchQueue.main.async { 
            self.currentBuffer = buffer 
            if self.bufferSize != size {
                self.bufferSize = size
            }
        }
    }
}

// MARK: - Main ViewModel with Performance Optimizations
@MainActor
class FaceRecognitionViewModel: ObservableObject {
    @Published var detectedFaces: [RecognizedFace] = []
    @Published var authStatus: String = "カメラ準備中..."
    @Published var isRegistering = false
    @Published var registrationProgress: Float = 0.0
    @Published var currentYaw: Float = 0.0
    @Published var currentPitch: Float = 0.0
    @Published var recognizedUserName: String = ""
    @Published var shouldAutoAttendance: Bool = false
    @Published var refreshID = UUID()
    @Published var bufferSize: CGSize = .zero

    private var tempSignatures: [[Float]] = []
    private let requiredSamples = 30
    private var lastSampleTime: Date = Date()
    private var lastSampleYaw: Float? = nil
    private var lastSamplePitch: Float? = nil
    
    // Quality metrics
    @Published var lightingStatus: LightingStatus = .good
    @Published var isFaceCentered: Bool = false
    @Published var faceCaptureQuality: Float = 0.0
    @Published var rotationAngle: CGFloat = 90

    enum LightingStatus: String {
        case dark = "暗すぎます"
        case bright = "明るすぎます"
        case good = "良好"
    }
    private let ciContext: CIContext
    private var embeddingCache: [String: (embedding: [Float], timestamp: Date)] = [:]
    private let cacheTimeout: TimeInterval = 5.0

    // Recognition stabilization
    private var recognitionHistory: [String: Int] = [:]
    private let recognitionThreshold = 3 // Need 3 consecutive recognitions

    // Precomputed centroid embeddings for faster & more accurate matching
    private var userCentroidCache: [(name: String, centroid: [Float])] = []
    private var lastRecognizedName: String = ""

    struct Candidate: Identifiable, Equatable {
        var id: String { name }
        let name: String
        let similarity: Float
        let status: UserAttendanceStatus

        static func == (lhs: Candidate, rhs: Candidate) -> Bool {
            lhs.name == rhs.name && lhs.similarity == rhs.similarity
        }
    }

    struct RecognizedFace: Identifiable {
        let id = UUID()
        let rect: CGRect
        var name: String = ""
        var score: Int = 0
        var rawSimilarity: Float = 0.0
        var landmarks: [String: [CGPoint]] = [:]
        var candidates: [Candidate] = []
        var attendanceStatus: UserAttendanceStatus = .notCheckedIn
    }

    let cameraManager = CameraManager()
    let store = FaceVectorStore()

    private var isProcessingFrame = false
    private var recognitionTask: Task<Void, Never>?
    private var model: AuraFace?
    private let processingQueue = DispatchQueue(label: "face.processing.queue", qos: .userInteractive, attributes: .concurrent)

    // Precomputed user embeddings for faster matching
    private var userEmbeddingsCache: [(name: String, embeddings: [[Float]])] = []

    init() {
        // Initialize CIContext with Metal for GPU acceleration
        if let metalDevice = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: metalDevice, options: [.cacheIntermediates: false])
        } else {
            ciContext = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
        }

        setupModel()
        cameraManager.start()
        authStatus = "顔を認識してください"

        // Load saved thresholds
        loadThresholdSettings()

        // Observe user changes to update cache
        observeUserChanges()
        
        // Orientation sync
        cameraManager.$rotationAngle
            .assign(to: \.rotationAngle, on: self)
            .store(in: &cancellables)
            
        // Buffer size sync
        cameraManager.$bufferSize
            .assign(to: \.bufferSize, on: self)
            .store(in: &cancellables)
    }
    
    private var cancellables = Set<AnyCancellable>()

    private func loadThresholdSettings() {
        let ud = UserDefaults.standard
        if ud.object(forKey: "rsp.matchThreshold") != nil { matchThreshold = ud.float(forKey: "rsp.matchThreshold") }
        if ud.object(forKey: "rsp.dropThreshold") != nil  { dropThreshold  = ud.float(forKey: "rsp.dropThreshold") }
        if ud.object(forKey: "rsp.smoothingAlpha") != nil { smoothingAlpha = ud.float(forKey: "rsp.smoothingAlpha") }
        if ud.object(forKey: "rsp.marginRequired") != nil { marginRequired = ud.float(forKey: "rsp.marginRequired") }

        let ud2 = UserDefaults.standard
        $matchThreshold.dropFirst().sink { ud2.set($0, forKey: "rsp.matchThreshold") }.store(in: &cancellables)
        $dropThreshold.dropFirst().sink  { ud2.set($0, forKey: "rsp.dropThreshold")  }.store(in: &cancellables)
        $smoothingAlpha.dropFirst().sink { ud2.set($0, forKey: "rsp.smoothingAlpha") }.store(in: &cancellables)
        $marginRequired.dropFirst().sink { ud2.set($0, forKey: "rsp.marginRequired") }.store(in: &cancellables)
    }

    func resetThresholds() {
        matchThreshold = 0.70
        dropThreshold  = 0.60
        smoothingAlpha = 0.25
        marginRequired = 0.04
    }

    private func observeUserChanges() {
        // Rebuild embeddings cache when users change
        Task {
            for await _ in store.$users.values {
                await rebuildEmbeddingsCache()
                // Notify observers that the store has changed
                self.objectWillChange.send()
            }
        }
    }

    private func rebuildEmbeddingsCache() async {
        userEmbeddingsCache = store.users.map { ($0.name, $0.faceSignatures) }
        // Also build centroid cache
        userCentroidCache = store.users.compactMap { user in
            guard !user.faceSignatures.isEmpty else { return nil }
            let centroid = computeCentroid(user.faceSignatures)
            return (user.name, centroid)
        }
    }

    /// Compute centroid (mean) of multiple embeddings and L2-normalize
    private func computeCentroid(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for emb in embeddings {
            guard emb.count == dim else { continue }
            vDSP_vadd(sum, 1, emb, 1, &sum, 1, vDSP_Length(dim))
        }
        var count = Float(embeddings.count)
        vDSP_vsdiv(sum, 1, &count, &sum, 1, vDSP_Length(dim))
        return l2NormalizeSIMD(sum)
    }

    private func setupModel() {
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            self.model = try AuraFace(configuration: config)
        } catch {
            self.authStatus = "モデルロードエラー"
        }
    }

    func processFrame(buffer: CVPixelBuffer) {
        let sendableBuffer = SendablePixelBuffer(buffer: buffer)
        guard !isProcessingFrame else { return }
        isProcessingFrame = true

        let request = VNDetectFaceLandmarksRequest { [weak self] req, error in
            Task { @MainActor [weak self] in
                guard let self = self else { return }
                
                guard let results = req.results as? [VNFaceObservation] else {
                    self.isProcessingFrame = false
                    return
                }

                self.updateFaceResults(with: results)
                self.isProcessingFrame = false

                if self.recognitionTask == nil {
                    self.recognitionTask = Task {
                        await self.performRecognition(on: sendableBuffer.buffer, observations: results)
                        self.recognitionTask = nil
                    }
                }
            }
        }
        request.revision = VNDetectFaceLandmarksRequestRevision3

        let faceCaptureRequest = VNDetectFaceCaptureQualityRequest { [weak self] req, _ in
            Task { @MainActor [weak self] in
                guard let self = self, let result = req.results?.first as? VNFaceObservation else { return }
                self.faceCaptureQuality = result.faceCaptureQuality ?? 0.0
                
                if self.faceCaptureQuality < 0.2 {
                    self.lightingStatus = .dark
                } else {
                    self.lightingStatus = .good
                }
                
                let centerX = result.boundingBox.midX
                let centerY = result.boundingBox.midY
                self.isFaceCentered = abs(centerX - 0.5) < 0.15 && abs(centerY - 0.5) < 0.15
            }
        }

        processingQueue.async { [weak self] in
            let handler = VNImageRequestHandler(cvPixelBuffer: sendableBuffer.buffer, orientation: .up, options: [:])
            do {
                try handler.perform([request, faceCaptureRequest])
            } catch {
                Task { @MainActor [weak self] in
                    self?.isProcessingFrame = false
                }
            }
        }
    }

    private func updateFaceResults(with observations: [VNFaceObservation]) {
        var newFaces: [RecognizedFace] = []
        for (index, obs) in observations.enumerated() {
            var face = RecognizedFace(rect: obs.boundingBox)
            if let landmarks = obs.landmarks {
                let rect = obs.boundingBox
                func transform(_ points: [CGPoint]?) -> [CGPoint]? {
                    return points?.map { pt in
                        CGPoint(x: rect.origin.x + pt.x * rect.width, y: rect.origin.y + pt.y * rect.height)
                    }
                }
                face.landmarks["outer"] = transform(landmarks.faceContour?.normalizedPoints)
                face.landmarks["leftEye"] = transform(landmarks.leftEye?.normalizedPoints)
                face.landmarks["rightEye"] = transform(landmarks.rightEye?.normalizedPoints)
                face.landmarks["nose"] = transform(landmarks.nose?.normalizedPoints)
                face.landmarks["lips"] = transform(landmarks.outerLips?.normalizedPoints)
                
            }
            if index < self.detectedFaces.count {
                face.name = self.detectedFaces[index].name
                face.score = self.detectedFaces[index].score
                face.rawSimilarity = self.detectedFaces[index].rawSimilarity
                face.candidates = self.detectedFaces[index].candidates
                face.attendanceStatus = self.detectedFaces[index].attendanceStatus
            }
            newFaces.append(face)
        }
        self.detectedFaces = newFaces
    }

    private func performRecognition(on buffer: CVPixelBuffer, observations: [VNFaceObservation]) async {
        for (index, observation) in observations.enumerated() {
            let embedding = await extractEmbeddingOptimized(from: buffer, rect: observation.boundingBox, landmarks: observation.landmarks)
            if !embedding.isEmpty {
                if self.isRegistering {
                    await self.collectSample(embedding, yaw: observation.yaw, pitch: observation.pitch)
                }

                let topMatches = await self.findTopMatchesOptimized(for: embedding)

                await MainActor.run {
                    if index < self.detectedFaces.count, let best = topMatches.first {
                        self.detectedFaces[index].candidates = topMatches
                        
                        // Margin check: best must be above second-best by marginRequired
                        let hasMargin: Bool
                        if topMatches.count >= 2 {
                            hasMargin = (best.similarity - topMatches[1].similarity) >= self.marginRequired
                        } else {
                            hasMargin = true
                        }
                        
                        let effectiveSimilarity = hasMargin ? best.similarity : best.similarity * 0.9
                        self.applySmoothResults(at: index, newName: best.name, newSimilarity: effectiveSimilarity, embedding: embedding)

                        // Update attendance status
                        let status = self.store.getTodayStatus(for: best.name)
                        self.detectedFaces[index].attendanceStatus = status

                        if effectiveSimilarity > 0.85 && hasMargin {
                            self.updateRecognitionHistory(name: best.name)
                        }
                    }
                }
            }
        }
    }

    private func updateRecognitionHistory(name: String) {
        // Increment recognition count
        recognitionHistory[name] = (recognitionHistory[name] ?? 0) + 1

        // Decay other entries
        for key in recognitionHistory.keys where key != name {
            recognitionHistory[key] = max(0, (recognitionHistory[key] ?? 0) - 1)
            if recognitionHistory[key] == 0 {
                recognitionHistory.removeValue(forKey: key)
            }
        }

        // Check if stable recognition
        if let count = recognitionHistory[name], count >= recognitionThreshold {
            if lastRecognizedName != name {
                lastRecognizedName = name
                recognizedUserName = name
                shouldAutoAttendance = true

                // Haptic feedback
                let impact = UIImpactFeedbackGenerator(style: .medium)
                impact.impactOccurred()
            }
        }
    }

    func resetAutoAttendance() {
        shouldAutoAttendance = false
        recognitionHistory.removeAll()
    }

    func resetAfterRegistration(employeeName: String) {
        shouldAutoAttendance = false
        recognitionHistory.removeAll()
        lastRecognizedName = employeeName
    }

    private func applySmoothResults(at index: Int, newName: String, newSimilarity: Float, embedding: [Float]) {
        var currentFace = self.detectedFaces[index]
        // EMA smoothing — lower alpha = more stable, slower to react
        let smoothedSim = (newSimilarity * smoothingAlpha) + (currentFace.rawSimilarity * (1.0 - smoothingAlpha))
        currentFace.rawSimilarity = smoothedSim

        let isCurrentlyRecognized = currentFace.name != "未認証" && currentFace.name != "認証中..." && !currentFace.name.isEmpty

        if smoothedSim > matchThreshold || (isCurrentlyRecognized && smoothedSim > dropThreshold && currentFace.name == newName) {
            currentFace.name = newName
            // Map smoothedSim → display %: matchThreshold→70%, matchThreshold+0.07→80%, 0.9+→92-100%
            let t = matchThreshold
            let displayScore: Int
            if smoothedSim >= 0.9 {
                displayScore = Int(92 + (smoothedSim - 0.9) * 80)
            } else if smoothedSim >= t + 0.07 {
                displayScore = Int(80 + (smoothedSim - (t + 0.07)) * 240)
            } else {
                displayScore = Int(70 + (smoothedSim - t) * (10.0 / 0.07))
            }
            currentFace.score = min(100, max(0, displayScore))
        } else {
            let penalty: Float = smoothedSim < dropThreshold ? 0.4 : 0.75
            let decayedScore = Float(currentFace.score) * penalty
            
            if decayedScore < 25 {
                currentFace.name = "未認証"
                // Map low similarities (e.g. 0.5-0.7) to very low scores (10-30%)
                currentFace.score = Int(max(0, (smoothedSim - 0.5) * 100))
            } else {
                currentFace.score = Int(decayedScore)
                if currentFace.score < 45 {
                    currentFace.name = "認証中..."
                }
            }
        }
        self.detectedFaces[index] = currentFace
    }

    // MARK: - Optimized Matching with SIMD + Centroid
    // MARK: - Tuning Parameters (UserDefaults-backed, editable from Settings)
    private let centroidWeight: Float = 0.75
    @Published var matchThreshold: Float = 0.70
    @Published var dropThreshold: Float = 0.60
    @Published var smoothingAlpha: Float = 0.25
    @Published var marginRequired: Float = 0.04

    private func findTopMatchesOptimized(for embedding: [Float], count: Int = 5) async -> [Candidate] {
        if userCentroidCache.isEmpty {
            await rebuildEmbeddingsCache()
            if userCentroidCache.isEmpty { return [] }
        }

        var allMatches: [Candidate] = []

        for (name, centroid) in userCentroidCache {
            let centroidSim = cosineSimilarity(embedding, centroid)

            // Best individual sample similarity
            var bestIndividualSim: Float = centroidSim
            if let sigs = userEmbeddingsCache.first(where: { $0.name == name })?.embeddings {
                let sampled = sigs.count > 20 ? Array(sigs.suffix(20)) : sigs
                for saved in sampled {
                    let sim = cosineSimilarity(embedding, saved)
                    if sim > bestIndividualSim { bestIndividualSim = sim }
                }
            }

            // Weighted blend (more centroid = more stable across frames)
            let blendedSim = centroidSim * centroidWeight + bestIndividualSim * (1.0 - centroidWeight)
            let status = store.getTodayStatus(for: name)
            allMatches.append(Candidate(name: name, similarity: blendedSim, status: status))
        }

        return allMatches.sorted { $0.similarity > $1.similarity }.prefix(count).map { $0 }
    }

    // Cosine similarity (equivalent to dot product for L2-normalized vectors)
    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dotProduct: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, vDSP_Length(a.count))
        
        var normA: Float = 0
        var normB: Float = 0
        vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
        
        let denom = sqrt(normA) * sqrt(normB)
        guard denom > 1e-6 else { return 0 }
        return dotProduct / denom
    }

    // MARK: - Optimized Embedding Extraction with Face Alignment
    private func extractEmbeddingOptimized(from buffer: CVPixelBuffer, rect: CGRect, landmarks: VNFaceLandmarks2D? = nil) async -> [Float] {
        guard let model = self.model else { return [] }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))

        // Add 20% margin around face for better context
        let marginX = rect.width * 0.2
        let marginY = rect.height * 0.2
        let expandedRect = CGRect(
            x: max(0, rect.origin.x - marginX),
            y: max(0, rect.origin.y - marginY),
            width: min(1.0 - max(0, rect.origin.x - marginX), rect.width + marginX * 2),
            height: min(1.0 - max(0, rect.origin.y - marginY), rect.height + marginY * 2)
        )

        let faceRect = CGRect(
            x: expandedRect.origin.x * width,
            y: expandedRect.origin.y * height,
            width: expandedRect.width * width,
            height: expandedRect.height * height
        )

        if faceRect.width < 30 || faceRect.height < 30 { return [] }

        var croppedImage = ciImage.cropped(to: faceRect)
        croppedImage = croppedImage.transformed(by: CGAffineTransform(translationX: -faceRect.origin.x, y: -faceRect.origin.y))

        // Face alignment using eye landmarks
        if let landmarks = landmarks,
           let leftEye = landmarks.leftEye?.normalizedPoints, !leftEye.isEmpty,
           let rightEye = landmarks.rightEye?.normalizedPoints, !rightEye.isEmpty {

            let leftCenter = CGPoint(
                x: leftEye.reduce(0.0) { $0 + $1.x } / CGFloat(leftEye.count),
                y: leftEye.reduce(0.0) { $0 + $1.y } / CGFloat(leftEye.count)
            )
            let rightCenter = CGPoint(
                x: rightEye.reduce(0.0) { $0 + $1.x } / CGFloat(rightEye.count),
                y: rightEye.reduce(0.0) { $0 + $1.y } / CGFloat(rightEye.count)
            )

            let angle = atan2(rightCenter.y - leftCenter.y, rightCenter.x - leftCenter.x)

            if abs(angle) > 0.02 { // Only align if tilt is significant
                let cropW = croppedImage.extent.width
                let cropH = croppedImage.extent.height
                let centerX = cropW / 2
                let centerY = cropH / 2

                let transform = CGAffineTransform(translationX: centerX, y: centerY)
                    .rotated(by: -angle)
                    .translatedBy(x: -centerX, y: -centerY)

                croppedImage = croppedImage.transformed(by: transform)
                // Re-crop to original size to remove rotation artifacts
                let newExtent = croppedImage.extent
                let cropRect = CGRect(
                    x: newExtent.midX - cropW / 2,
                    y: newExtent.midY - cropH / 2,
                    width: cropW,
                    height: cropH
                )
                croppedImage = croppedImage.cropped(to: cropRect)
                croppedImage = croppedImage.transformed(by: CGAffineTransform(
                    translationX: -croppedImage.extent.origin.x,
                    y: -croppedImage.extent.origin.y
                ))
            }
        }

        // AuraFace expects 112x112 input (normalization is built into the model)
        let scale = 112.0 / max(croppedImage.extent.width, croppedImage.extent.height)
        let finalImage = croppedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        guard let faceBuffer = ciImageToPixelBuffer(finalImage) else { return [] }

        do {
            let input = AuraFaceInput(face_input: faceBuffer)
            let output = try await model.prediction(input: input)
            let embeddings = output.embedding
            var result = [Float](repeating: 0, count: embeddings.count)
            let embPtr = embeddings.dataPointer.assumingMemoryBound(to: Float.self)
            for i in 0..<embeddings.count { result[i] = embPtr[i] }
            return l2NormalizeSIMD(result)
        } catch { return [] }
    }

    private func ciImageToPixelBuffer(_ image: CIImage) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferCGImageCompatibilityKey: kCFBooleanTrue!,
            kCVPixelBufferCGBitmapContextCompatibilityKey: kCFBooleanTrue!
        ] as CFDictionary
        CVPixelBufferCreate(kCFAllocatorDefault, 112, 112, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer)
        guard let pb = pixelBuffer else { return nil }
        ciContext.render(image, to: pb)
        return pb
    }

    private func l2NormalizeSIMD(_ vector: [Float]) -> [Float] {
        var sumSquares: Float = 0
        vDSP_svesq(vector, 1, &sumSquares, vDSP_Length(vector.count))
        let norm = sqrt(sumSquares)
        guard norm > 1e-6 else { return vector }

        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    // MARK: - Registration

    func startRegistration() {
        tempSignatures = []
        registrationProgress = 0
        isRegistering = true
        lastSampleYaw = nil
        lastSamplePitch = nil
        authStatus = "カメラを見てください"
    }

    func cancelRegistration() {
        tempSignatures = []
        registrationProgress = 0
        isRegistering = false
        lastSampleYaw = nil
        lastSamplePitch = nil
        authStatus = "顔を認識してください"
    }

    private func collectSample(_ embedding: [Float], yaw: NSNumber?, pitch: NSNumber? = nil) async {
        // Simple time-based throttle
        if Date().timeIntervalSince(lastSampleTime) < 0.15 { return }

        let currentYawValue = yaw?.floatValue ?? 0.0
        let currentPitchValue = pitch?.floatValue ?? 0.0

        await MainActor.run {
            self.currentYaw = currentYawValue
            self.currentPitch = currentPitchValue
        }

        // Quality gate: reject low quality samples
        let quality = await MainActor.run { self.faceCaptureQuality }
        if quality < 0.18 { return } // Reject blurry/dark samples

        // Prefer different angles but don't block if same angle
        if let lastYaw = lastSampleYaw, tempSignatures.count < requiredSamples - 3 {
            let yawDiff = abs(currentYawValue - lastYaw)
            let pitchDiff = abs(currentPitchValue - (lastSamplePitch ?? 0))
            if yawDiff < 0.04 && pitchDiff < 0.04 {
                return // Skip only if very similar and not near the end
            }
        }

        tempSignatures.append(embedding)
        lastSampleTime = Date()
        lastSampleYaw = currentYawValue
        lastSamplePitch = currentPitchValue

        let progress = Float(tempSignatures.count) / Float(requiredSamples)
        await MainActor.run {
            self.registrationProgress = min(progress, 1.0)
            if self.tempSignatures.count >= self.requiredSamples {
                self.isRegistering = false
                self.authStatus = "登録準備完了"
            }
        }
    }

    func finalizeRegistration(name: String) {
        store.saveUser(FaceUser(id: UUID().uuidString, name: name, department: "本社", faceSignatures: tempSignatures))
        tempSignatures = []
        registrationProgress = 0

        // Rebuild cache
        Task {
            await rebuildEmbeddingsCache()
        }

        authStatus = "\(name)さんの登録が完了しました"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.authStatus = "顔を認識してください"
        }
    }

    // MARK: - Attendance Actions
    func performAutoAttendance() {
        guard !recognizedUserName.isEmpty else { return }

        let status = store.getTodayStatus(for: recognizedUserName)

        switch status {
        case .notCheckedIn:
            store.checkIn(userName: recognizedUserName)
            authStatus = "\(recognizedUserName)さん 出勤しました"
        case .checkedIn:
            store.checkOut(userName: recognizedUserName)
            authStatus = "\(recognizedUserName)さん 退勤しました"
        case .checkedOut:
            authStatus = "\(recognizedUserName)さんは既に退勤済みです"
        }

        // Haptic feedback
        let notification = UINotificationFeedbackGenerator()
        notification.notificationOccurred(.success)

        resetAutoAttendance()

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            self.authStatus = "顔を認識してください"
        }
    }

    // MARK: - Backup & Restore
    func backupData() {
        store.backupDatabase()
        authStatus = "バックアップ完了"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.authStatus = "顔を認識してください"
        }
    }

    func restoreData() {
        store.restoreFromBackup()
        Task {
            await rebuildEmbeddingsCache()
        }
        authStatus = "復元完了"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            self.authStatus = "顔を認識してください"
        }
    }
}
