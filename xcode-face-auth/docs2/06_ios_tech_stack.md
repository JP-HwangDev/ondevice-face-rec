# 06. iOS 기술 스택 상세 (iOS Tech Stack)

> 각 계층별 선정 라이브러리/프레임워크와 그 역할을 코드 수준에서 설명합니다.

---

## 6.1 전체 기술 스택 한눈에 보기

| 레이어 | 기술 | 라이선스 | 선정 이유 |
|---|---|---|---|
| **UI** | SwiftUI (ZStack) | Apple SDK | AR 오버레이, 얼굴 가이드 박스 구현에 최적 |
| **카메라** | AVFoundation (`AVCaptureVideoDataOutput`) | Apple SDK | 커스텀 프레임 단위 처리 필수 |
| **얼굴 탐지** | Vision (`VNDetectFaceRectanglesRequest`) | Apple SDK | 빠른 탐지, 랜드마크 불필요 시 최적 |
| **얼굴 인식** | Core ML + MobileFaceNet (.mlpackage) | Apache 2.0 | 512차원 임베딩 추출, ANE 가속 |
| **Liveness** | ARKit + TrueDepth | Apple SDK | Depth 맵으로 평면(사진) 판별 |
| **벡터 연산** | Accelerate (vDSP/SIMD) | Apple SDK | Cosine Similarity 초고속 계산 |
| **로컬 DB** | GRDB.swift + SQLite | MIT | 임베딩 벡터 Data 직렬화 저장 |
| **보안 저장** | Keychain Services + CryptoKit | Apple SDK | 생체 데이터 하드웨어 암호화 |
| **모델 변환** | coremltools (Python) | BSD-3-Clause | PyTorch → Core ML 변환 공식 도구 |
| **비동기** | Swift Concurrency (async/await) | Swift OSS | 카메라-AI 추론-UI 분리 처리 |

---

## 6.2 카메라 파이프라인 (AVFoundation)

```swift
import AVFoundation

class CameraManager: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let processingQueue = DispatchQueue(label: "face.processing", qos: .userInitiated)

    func setupCamera() {
        session.beginConfiguration()
        session.sessionPreset = .high

        // 전면 카메라 선택
        guard let device = AVCaptureDevice.default(.builtInTrueDepthCamera,
                                                    for: .video,
                                                    position: .front) else { return }
        guard let input = try? AVCaptureDeviceInput(device: device) else { return }
        session.addInput(input)

        // 프레임 출력 설정
        videoOutput.setSampleBufferDelegate(self, queue: processingQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true  // 처리 못한 프레임 자동 폐기
        session.addOutput(videoOutput)
        session.commitConfiguration()
        session.startRunning()
    }

    // 매 프레임마다 호출됨 (약 30fps)
    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        // 핵심: CMSampleBuffer → CVPixelBuffer 변환
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        Task {
            await FaceRecognitionPipeline.shared.process(pixelBuffer)
        }
    }
}
```

**핵심 포인트:**
- `alwaysDiscardsLateVideoFrames = true`: 처리가 밀리면 프레임을 버려서 UI 멈춤 방지
- `processingQueue`: 메인 스레드가 아닌 별도 큐에서 프레임 처리

---

## 6.3 얼굴 탐지 (Vision Framework)

```swift
import Vision

func detectFace(in pixelBuffer: CVPixelBuffer) async -> VNFaceObservation? {
    return await withCheckedContinuation { continuation in
        let request = VNDetectFaceRectanglesRequest { request, error in
            guard let results = request.results as? [VNFaceObservation],
                  let face = results.first else {
                continuation.resume(returning: nil)
                return
            }
            continuation.resume(returning: face)
        }

        // 이미지 방향 명시 — 생략 시 인식률 급락
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: .leftMirrored,  // 전면 카메라 미러링 보정
            options: [:]
        )
        try? handler.perform([request])
    }
}
```

**핵심 포인트:**
- `orientation` 설정 필수: 전면 카메라는 `.leftMirrored`, 후면은 `.right` 등 기기마다 다름
- `VNDetectFaceRectanglesRequest` vs `VNDetectFaceLandmarksRequest`: 랜드마크 불필요 시 전자가 2~3배 빠름

---

## 6.4 얼굴 전처리 (Crop & Resize)

```swift
import CoreImage
import CoreVideo

func cropAndResize(pixelBuffer: CVPixelBuffer,
                   boundingBox: CGRect,
                   targetSize: CGSize = CGSize(width: 112, height: 112)) -> CVPixelBuffer? {
    let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
    let imageSize = CGSize(
        width: CVPixelBufferGetWidth(pixelBuffer),
        height: CVPixelBufferGetHeight(pixelBuffer)
    )

    // Vision의 normalized coordinates (0~1) → 실제 픽셀 좌표 변환
    // Vision은 좌하단 기준 좌표계 사용 → CIImage 좌상단 기준으로 변환 필요
    let rect = VNImageRectForNormalizedRect(boundingBox, Int(imageSize.width), Int(imageSize.height))
    let flippedRect = CGRect(
        x: rect.origin.x,
        y: imageSize.height - rect.origin.y - rect.height,
        width: rect.width,
        height: rect.height
    )

    let cropped = ciImage.cropped(to: flippedRect)
    let scaled = cropped.transformed(by: CGAffineTransform(
        scaleX: targetSize.width / flippedRect.width,
        y: targetSize.height / flippedRect.height
    ))

    // CVPixelBuffer로 변환
    var outputBuffer: CVPixelBuffer?
    CVPixelBufferCreate(nil, Int(targetSize.width), Int(targetSize.height),
                        kCVPixelFormatType_32BGRA, nil, &outputBuffer)
    guard let output = outputBuffer else { return nil }
    CIContext().render(scaled, to: output)
    return output
}
```

---

## 6.5 Core ML 추론 (Embedding 추출)

```swift
import CoreML

class FaceEmbeddingExtractor {
    private let model: MobileFaceNet

    init() {
        // Xcode가 .mlpackage에서 자동 생성한 Swift 클래스 사용
        let config = MLModelConfiguration()
        config.computeUnits = .all  // CPU + GPU + ANE 자동 선택
        self.model = try! MobileFaceNet(configuration: config)
    }

    func extract(from pixelBuffer: CVPixelBuffer) -> [Float]? {
        guard let input = try? MobileFaceNetInput(face_input: pixelBuffer),
              let output = try? model.prediction(input: input) else { return nil }

        // MLMultiArray → [Float] 변환
        let embeddingArray = output.output  // MLMultiArray (512 dim)
        return (0..<embeddingArray.count).map { Float(truncating: embeddingArray[$0]) }
    }
}
```

**핵심 포인트:**
- `computeUnits = .all`: Apple Neural Engine(ANE) 자동 활용으로 배터리 효율 최대화
- `.mlpackage` 포맷 사용 권장 (`.mlmodel`보다 최신 기능 지원)

---

## 6.6 벡터 유사도 계산 (Accelerate Framework)

```swift
import Accelerate

struct VectorMath {
    /// Cosine Similarity 계산
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return -1.0 }
        let n = vDSP_Length(a.count)

        var dotProduct: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dotProduct, n)

        var normA: Float = 0
        var normB: Float = 0
        vDSP_svesq(a, 1, &normA, n)  // sum of squares
        vDSP_svesq(b, 1, &normB, n)

        let magnitude = sqrt(normA) * sqrt(normB)
        guard magnitude > 0 else { return 0 }
        return dotProduct / magnitude
    }

    /// L2 정규화 (임베딩 정규화 필수)
    static func l2Normalize(_ vector: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(vector, 1, &norm, vDSP_Length(vector.count))
        norm = sqrt(norm)
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }
}
```

---

## 6.7 로컬 DB (GRDB.swift)

```swift
import GRDB

struct EmployeeEmbedding: Codable, FetchableRecord, PersistableRecord {
    var id: String           // 직원 ID (예: "EMP001")
    var name: String
    var embeddingData: Data  // [Float] → Data 직렬화
    var updatedAt: Date

    // [Float] ↔ Data 변환 헬퍼
    var embedding: [Float] {
        get { embeddingData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
        set { embeddingData = newValue.withUnsafeBytes { Data($0) } }
    }
}

class EmbeddingDatabase {
    private var db: DatabaseQueue!

    func setup(encryptionKey: Data? = nil) throws {
        var config = Configuration()
        // SQLCipher 암호화 설정 (선택사항)
        if let key = encryptionKey {
            config.prepareDatabase { db in
                try db.usePassphrase(key)
            }
        }
        db = try DatabaseQueue(path: dbPath, configuration: config)
        try db.write { db in
            try db.create(table: "employeeEmbedding", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("embeddingData", .blob).notNull()
                t.column("updatedAt", .datetime).notNull()
            }
        }
    }

    /// 유사도 상위 3명 반환 (화면 하단 후보 표시용)
    func findTopMatches(for query: [Float], topK: Int = 3) throws -> [(id: String, name: String, score: Float)] {
        let normalized = VectorMath.l2Normalize(query)
        let records = try db.read { db in
            try EmployeeEmbedding.fetchAll(db)
        }

        return records
            .map { record -> (String, String, Float) in
                let stored = VectorMath.l2Normalize(record.embedding)
                let score = VectorMath.cosineSimilarity(normalized, stored)
                return (record.id, record.name, score)
            }
            .sorted { $0.2 > $1.2 }   // 유사도 내림차순 정렬
            .prefix(topK)              // 상위 3명만 추출
            .map { (id: $0.0, name: $0.1, score: $0.2) }
    }
}
```

---

## 6.8 보안 저장 (Keychain + CryptoKit)

```swift
import Security
import CryptoKit

class BiometricDataVault {
    private let keychainService = "com.company.faceauth"

    /// DB 암호화 키를 Keychain에 저장/조회
    func getDatabaseEncryptionKey() -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "db_encryption_key",
            kSecReturnData as String: true
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        if status == errSecSuccess, let data = result as? Data {
            return data
        }

        // 최초 실행: 256비트 키 생성 후 Keychain 저장
        let newKey = SymmetricKey(size: .bits256)
        let keyData = newKey.withUnsafeBytes { Data($0) }
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: "db_encryption_key",
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
        return keyData
    }
}
```

**핵심 포인트:**
- `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`: 다른 기기 복원 시 접근 불가 — 가장 강력한 보호
- CryptoKit의 `SymmetricKey`로 256비트 AES 암호화 키 생성
