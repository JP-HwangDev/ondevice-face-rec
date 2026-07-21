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
    private let frameSkipInterval = 2 // Every 2nd frame — faster recognition, still saves some CPU

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
    private let requiredSamples = 12
    private var lastSampleTime: Date = Date()
    private var lastSampleYaw: Float? = nil
    private var lastSamplePitch: Float? = nil
    
    // Quality metrics
    @Published var lightingStatus: LightingStatus = .good
    @Published var isFaceCentered: Bool = false
    @Published var faceCaptureQuality: Float = 0.0
    @Published var rotationAngle: CGFloat = 90

    // Mask detection (heuristic — no ML model, no external assets)
    @Published var isMaskDetected: Bool = false
    @Published var maskColorDistanceThreshold: Float = 30
    private var maskScore: Int = 0
    private let maskScoreMax = 6
    private let maskOnScore = 3   // net evidence needed to flip ON
    private let maskOffScore = 2  // score must fall back to this to flip OFF (hysteresis)

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
    private let recognitionThreshold = 2 // Need 2 consecutive recognitions

    // The embedding/user behind the most recent high-confidence recognition, held so it
    // can be folded into the user's stored signatures once checkIn/checkOut actually commits.
    private var pendingAttendanceUserId: String?
    private var pendingAttendanceEmbedding: [Float]?

    // Precomputed centroid embeddings for faster & more accurate matching
    private var userCentroidCache: [(user: FaceUser, centroid: [Float])] = []
    private var lastRecognizedKey: String = ""

    struct Candidate: Identifiable, Equatable {
        var id: String { userId }
        let userId: String
        let name: String
        let department: String
        let userType: FaceUserType
        let visitPurpose: String?
        let similarity: Float
        let status: UserAttendanceStatus
        var isVisitor: Bool { userType == .visitor }

        static func == (lhs: Candidate, rhs: Candidate) -> Bool {
            lhs.userId == rhs.userId && lhs.similarity == rhs.similarity
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
    private var userEmbeddingsCache: [(user: FaceUser, embeddings: [[Float]])] = []

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
        if ud.object(forKey: "rsp.maskColorDistanceThreshold") != nil { maskColorDistanceThreshold = ud.float(forKey: "rsp.maskColorDistanceThreshold") }

        let ud2 = UserDefaults.standard
        $matchThreshold.dropFirst().sink { ud2.set($0, forKey: "rsp.matchThreshold") }.store(in: &cancellables)
        $dropThreshold.dropFirst().sink  { ud2.set($0, forKey: "rsp.dropThreshold")  }.store(in: &cancellables)
        $smoothingAlpha.dropFirst().sink { ud2.set($0, forKey: "rsp.smoothingAlpha") }.store(in: &cancellables)
        $marginRequired.dropFirst().sink { ud2.set($0, forKey: "rsp.marginRequired") }.store(in: &cancellables)
        $maskColorDistanceThreshold.dropFirst().sink { ud2.set($0, forKey: "rsp.maskColorDistanceThreshold") }.store(in: &cancellables)
    }

    func resetThresholds() {
        matchThreshold = 0.70
        dropThreshold  = 0.60
        smoothingAlpha = 0.25
        marginRequired = 0.04
        maskColorDistanceThreshold = 30
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
        userEmbeddingsCache = store.users.map { ($0, $0.faceSignatures) }
        // Also build centroid cache
        userCentroidCache = store.users.compactMap { user in
            guard !user.faceSignatures.isEmpty else { return nil }
            let centroid = computeCentroid(user.faceSignatures)
            return (user, centroid)
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

        // Rectangles: Vision's mask/occlusion-robust detector (revision 3). This is the
        // authoritative face list, so bounding boxes still appear when a face mask is worn.
        let rectanglesRequest = VNDetectFaceRectanglesRequest()
        rectanglesRequest.revision = VNDetectFaceRectanglesRequestRevision3

        // Landmarks: best-effort only. Under occlusion this can return fewer faces than
        // the rectangles request (sometimes none at all), so it must never gate detection.
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        landmarksRequest.revision = VNDetectFaceLandmarksRequestRevision3

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
                try handler.perform([rectanglesRequest, landmarksRequest, faceCaptureRequest])
            } catch {
                Task { @MainActor [weak self] in
                    self?.isProcessingFrame = false
                }
                return
            }

            let rectResults = (rectanglesRequest.results as? [VNFaceObservation]) ?? []
            let landmarkResults = (landmarksRequest.results as? [VNFaceObservation]) ?? []

            // Attach landmarks where a matching face was also found by the landmarks pass;
            // otherwise keep the rectangles-only observation so masked faces still show up.
            let merged: [VNFaceObservation] = rectResults.map { rectObs in
                landmarkResults.first { FaceRecognitionViewModel.iou($0.boundingBox, rectObs.boundingBox) > 0.5 } ?? rectObs
            }

            Task { @MainActor [weak self] in
                guard let self = self else { return }

                // Mask state must be known before building the display model, so the
                // mouth/nose contour can be suppressed instead of flickering per-frame.
                self.updateMaskDetection(buffer: sendableBuffer.buffer, observations: merged)
                self.updateFaceResults(with: merged)
                self.isProcessingFrame = false

                if self.recognitionTask == nil {
                    self.recognitionTask = Task {
                        await self.performRecognition(on: sendableBuffer.buffer, observations: merged)
                        self.recognitionTask = nil
                    }
                }
            }
        }
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull, !inter.isEmpty else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        guard unionArea > 0 else { return 0 }
        return interArea / unionArea
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
                face.landmarks["leftEye"] = transform(landmarks.leftEye?.normalizedPoints)
                face.landmarks["rightEye"] = transform(landmarks.rightEye?.normalizedPoints)

                // Nose/mouth/contour are unreliable (Vision sometimes still guesses at
                // them) once a mask is flagged, so suppress them instead of letting the
                // outline flicker between a full face and a partial one every frame.
                if !isMaskDetected {
                    face.landmarks["outer"] = transform(landmarks.faceContour?.normalizedPoints)
                    face.landmarks["nose"] = transform(landmarks.nose?.normalizedPoints)
                    face.landmarks["lips"] = transform(landmarks.outerLips?.normalizedPoints)
                }
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

    // MARK: - Mask Detection (heuristic)
    // No mask-classifier model is bundled (to avoid using a pretrained model of unclear
    // license). Instead we compare the average color of the nose/mouth/chin area against
    // an eye-level cheek patch — mask fabric color usually diverges from skin tone there,
    // while an unobstructed lower face stays close to the reference. Approximate, but
    // requires no extra assets.
    private func updateMaskDetection(buffer: CVPixelBuffer, observations: [VNFaceObservation]) {
        guard let primary = observations.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            maskScore = 0
            isMaskDetected = false
            return
        }

        // Hysteresis counter instead of a strict consecutive-frame streak: a single noisy
        // reading no longer resets progress to zero, so a real mask still gets flagged
        // even if a frame or two reads as "clear", and a real face doesn't flicker off
        // from a single false-positive frame either.
        if detectMaskHeuristically(buffer: buffer, observation: primary) {
            maskScore = min(maskScore + 1, maskScoreMax)
        } else {
            maskScore = max(maskScore - 1, 0)
        }

        if !isMaskDetected && maskScore >= maskOnScore {
            isMaskDetected = true
        } else if isMaskDetected && maskScore <= maskOffScore {
            isMaskDetected = false
        }
    }

    private func detectMaskHeuristically(buffer: CVPixelBuffer, observation: VNFaceObservation) -> Bool {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let width = CGFloat(CVPixelBufferGetWidth(buffer))
        let height = CGFloat(CVPixelBufferGetHeight(buffer))
        let rect = observation.boundingBox
        guard rect.width > 0, rect.height > 0 else { return false }

        func regionRect(x: ClosedRange<CGFloat>, y: ClosedRange<CGFloat>) -> CGRect {
            let x0 = rect.minX + x.lowerBound * rect.width
            let x1 = rect.minX + x.upperBound * rect.width
            let y0 = rect.minY + y.lowerBound * rect.height
            let y1 = rect.minY + y.upperBound * rect.height
            return CGRect(x: x0 * width, y: y0 * height, width: (x1 - x0) * width, height: (y1 - y0) * height)
        }

        // Vision's normalized space is bottom-left origin, y-up — same as CIImage's.
        // Deliberately avoid the lips/mouth: they're naturally a different color from
        // forehead skin (redder, more saturated) even with no mask at all, which was
        // causing false positives that never cleared. The chin tip just below the mouth
        // is bare skin on an unmasked face and should closely match the forehead — but
        // gets covered by fabric the moment a mask is worn.
        let lowerFaceRegion = regionRect(x: 0.35...0.65, y: 0.02...0.12)      // chin tip, below the lips
        let referenceSkinRegion = regionRect(x: 0.30...0.70, y: 0.78...0.92) // forehead

        guard let lower = averageColor(of: ciImage, in: lowerFaceRegion),
              let reference = averageColor(of: ciImage, in: referenceSkinRegion) else { return false }

        let dr = lower.r - reference.r
        let dg = lower.g - reference.g
        let db = lower.b - reference.b
        return sqrt(dr * dr + dg * dg + db * db) > maskColorDistanceThreshold
    }

    private func averageColor(of image: CIImage, in rect: CGRect) -> (r: Float, g: Float, b: Float)? {
        guard rect.width >= 4, rect.height >= 4 else { return nil }
        let extent = CIVector(x: rect.origin.x, y: rect.origin.y, z: rect.width, w: rect.height)
        guard let filter = CIFilter(name: "CIAreaAverage", parameters: [kCIInputImageKey: image, kCIInputExtentKey: extent]),
              let output = filter.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        return (Float(pixel[0]), Float(pixel[1]), Float(pixel[2]))
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

                        if effectiveSimilarity > 0.85 && hasMargin && !self.isMaskDetected {
                            self.updateRecognitionHistory(candidate: best, embedding: embedding)
                        }
                    }
                }
            }
        }
    }

    private func updateRecognitionHistory(candidate: Candidate, embedding: [Float]) {
        guard !candidate.isVisitor else { return }

        let name = candidate.name
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
            if lastRecognizedKey != candidate.id {
                lastRecognizedKey = candidate.id
                recognizedUserName = name
                // Kept for the checkIn/checkOut that follows, so the confidently-matched
                // frame can be folded back into the user's stored signatures.
                pendingAttendanceUserId = candidate.userId
                pendingAttendanceEmbedding = embedding
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
        pendingAttendanceUserId = nil
        pendingAttendanceEmbedding = nil
    }

    func resetAfterRegistration(employeeName: String) {
        shouldAutoAttendance = false
        recognitionHistory.removeAll()
        lastRecognizedKey = store.user(named: employeeName)?.id ?? employeeName
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

        for (user, centroid) in userCentroidCache {
            let centroidSim = cosineSimilarity(embedding, centroid)

            // Best individual sample similarity
            var bestIndividualSim: Float = centroidSim
            if let sigs = userEmbeddingsCache.first(where: { $0.user.id == user.id })?.embeddings {
                let sampled = sigs.count > 20 ? Array(sigs.suffix(20)) : sigs
                for saved in sampled {
                    let sim = cosineSimilarity(embedding, saved)
                    if sim > bestIndividualSim { bestIndividualSim = sim }
                }
            }

            // Weighted blend (more centroid = more stable across frames)
            let blendedSim = centroidSim * centroidWeight + bestIndividualSim * (1.0 - centroidWeight)
            let status = user.isVisitor ? .notCheckedIn : store.getTodayStatus(for: user.name)
            allMatches.append(Candidate(
                userId: user.id,
                name: user.name,
                department: user.department,
                userType: user.userType,
                visitPurpose: user.visitPurpose,
                similarity: blendedSim,
                status: status
            ))
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
        // Don't collect samples while a mask is detected — ask the user to remove it instead
        if isMaskDetected { return }

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
        finishRegistration(name: name)
    }

    func finalizeVisitorRegistration(name: String, company: String, purpose: String) {
        store.saveUser(FaceUser(
            id: UUID().uuidString,
            name: name,
            department: company,
            faceSignatures: tempSignatures,
            userType: .visitor,
            visitPurpose: purpose
        ))
        finishRegistration(name: name)
    }

    private func finishRegistration(name: String) {
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

    func currentFrameJPEGBase64() -> String? {
        guard let buffer = cameraManager.currentBuffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: 0.75) else { return nil }
        return "data:image/jpeg;base64,\(data.base64EncodedString())"
    }

    // MARK: - Attendance Actions
    func performAutoAttendance() {
        guard !recognizedUserName.isEmpty else { return }

        let status = store.getTodayStatus(for: recognizedUserName)

        switch status {
        case .notCheckedIn:
            store.checkIn(userName: recognizedUserName)
            authStatus = "\(recognizedUserName)さん 出勤しました"
            saveAttendanceEmbeddingIfAvailable()
        case .checkedIn:
            store.checkOut(userName: recognizedUserName)
            authStatus = "\(recognizedUserName)さん 退勤しました"
            saveAttendanceEmbeddingIfAvailable()
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

    /// Folds the embedding behind this attendance event back into the user's stored
    /// signatures, so recognition keeps adapting (lighting, aging, angle) without requiring
    /// a long re-registration. Only called for high-confidence matches (see
    /// updateRecognitionHistory), so misrecognitions can't poison the stored signatures.
    private func saveAttendanceEmbeddingIfAvailable() {
        guard let userId = pendingAttendanceUserId, let embedding = pendingAttendanceEmbedding else { return }
        store.appendSignature(userId: userId, vector: embedding)
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
