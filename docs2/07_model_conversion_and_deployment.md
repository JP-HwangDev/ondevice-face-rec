# 07. 모델 변환 및 배포 가이드 (Model Conversion & Deployment)

> Windows Python 환경에서 MobileFaceNet을 Core ML로 변환하고, iPhone에 탑재하는 전 과정

---

## 7.1 전체 개발 흐름

```
[Windows PC — Python]                    [Mac — Xcode]
─────────────────────                    ──────────────────────────
① 환경 설정                               ④ .mlpackage 드래그 앤 드롭
② MobileFaceNet 모델 로드  →  파일 전송  → ⑤ Swift 클래스 자동 생성
③ 양자화 + Core ML 변환                   ⑥ 앱 비즈니스 로직 구현
   → MobileFaceNet.mlpackage              ⑦ 실기기 빌드 & 테스트
```

---

## 7.2 단계별 실행 가이드

### 1단계: Windows 환경 준비

```bash
# Python 3.9 ~ 3.11 권장 (3.12 이상은 coremltools 호환성 확인 필요)
python --version

# 필수 패키지 설치
pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu
pip install coremltools==7.2
pip install numpy pillow

# 설치 확인
python -c "import torch; import coremltools as ct; print(ct.__version__)"
```

**⚠️ 주의사항:**
- `coremltools`는 Windows에서도 변환 가능하나 일부 기능은 Mac에서만 검증됨
- GPU 가속 변환은 Mac에서만 가능 (Windows는 CPU 변환)

---

### 2단계: MobileFaceNet 모델 준비

```python
# GitHub 추천 소스:
# https://github.com/cavalleria/cavaface.pytorch
# https://github.com/deepinsight/insightface

import torch
import torch.nn as nn

# 방법 A: 사전 학습 가중치(.pt) 직접 로드
model = MobileFaceNet(embedding_size=512)
checkpoint = torch.load("mobilefacenet.pt", map_location="cpu")
model.load_state_dict(checkpoint)
model.eval()  # ← 반드시 eval 모드로 전환 (Dropout, BN 고정)

# 방법 B: ONNX 경유 변환 (호환성 문제 시)
torch.onnx.export(
    model,
    torch.randn(1, 3, 112, 112),
    "mobilefacenet.onnx",
    input_names=["face_input"],
    output_names=["embedding_output"],
    opset_version=11
)
```

---

### 3단계: Core ML 변환 + 양자화 (핵심)

```python
import coremltools as ct
import torch

def convert_to_coreml(model, save_path: str = "MobileFaceNet.mlpackage"):
    model.eval()

    # 입력 형태: [배치=1, 채널=3, 높이=112, 너비=112]
    example_input = torch.randn(1, 3, 112, 112)

    # TorchScript로 변환 (Core ML 변환의 전처리 단계)
    traced_model = torch.jit.trace(model, example_input)

    # Core ML 변환 설정
    mlmodel = ct.convert(
        traced_model,
        inputs=[
            ct.ImageType(
                name="face_input",
                shape=(1, 3, 112, 112),
                # 정규화: ImageNet 기준 평균/표준편차 적용 (모델 학습 설정에 맞출 것)
                bias=[-0.485/0.229, -0.456/0.224, -0.406/0.225],
                scale=1.0 / (255.0 * 0.229)
            )
        ],
        outputs=[ct.TensorType(name="embedding_output")],
        # 양자화 옵션 (아래 비교표 참조)
        compute_precision=ct.precision.FLOAT16,  # 권장: Float16
        minimum_deployment_target=ct.target.iOS16
    )

    # 메타데이터 추가 (Xcode에서 표시됨)
    mlmodel.short_description = "MobileFaceNet Face Embedding Extractor"
    mlmodel.author = "Your Company"
    mlmodel.version = "1.0"

    mlmodel.save(save_path)
    print(f"✅ 저장 완료: {save_path}")
    print(f"📦 파일 크기: {os.path.getsize(save_path) / 1024 / 1024:.1f} MB")

convert_to_coreml(model)
```

### 양자화 옵션 비교

| 옵션 | 파일 크기 | 정확도 손실 | 추론 속도 | 권장 용도 |
|---|---|---|---|---|
| `FLOAT32` (원본) | ~18 MB | 없음 | 기준 | 개발/디버깅 |
| `FLOAT16` | ~9 MB | 미미함 (<0.1%) | 1.5~2x 빠름 | **프로덕션 권장** |
| `INT8` (가중치만) | ~5 MB | 소폭 (0.5~1%) | 2x 빠름 | 저사양 기기 |
| `INT4` (완전 양자화) | ~3 MB | 중간 (1~3%) | 2.5x 빠름 | 극한 경량화 필요 시 |

```python
# 고급: 선택적 양자화 (가중치만 INT8, 활성화는 Float16)
import coremltools.optimize.coreml as cto

op_config = cto.OpLinearQuantizerConfig(
    mode="linear_symmetric",
    dtype="int8",
    granularity="per_channel"
)
config = cto.OptimizationConfig(global_config=op_config)
compressed_model = cto.linear_quantize_weights(mlmodel, config=config)
compressed_model.save("MobileFaceNet_INT8.mlpackage")
```

---

### 4단계: 파일 전송 및 Xcode 통합

```
[Windows]
  MobileFaceNet.mlpackage (폴더 형태)
        ↓
  압축: zip MobileFaceNet.mlpackage.zip
        ↓
  전송: Google Drive / USB / 카카오톡
        ↓
[Mac]
  압축 해제 → MobileFaceNet.mlpackage 폴더 복원
        ↓
  Xcode 프로젝트 → [Project Navigator]에 드래그 앤 드롭
        ↓
  "Copy items if needed" 체크 → Add
```

**Xcode 자동 생성 Swift 클래스 확인:**
```swift
// Xcode가 자동으로 생성하는 파일 (직접 수정 불필요)
// MobileFaceNet.swift
class MobileFaceNet {
    init(configuration: MLModelConfiguration) throws
    func prediction(input: MobileFaceNetInput) throws -> MobileFaceNetOutput
}

class MobileFaceNetInput {
    var face_input: CVPixelBuffer  // ← 입력 이름은 변환 시 설정한 이름과 일치
}

class MobileFaceNetOutput {
    var embedding_output: MLMultiArray  // ← 512차원 벡터
}
```

---

### 5단계: 변환 결과 검증

```python
# Python에서 변환 전/후 출력 비교 (Windows)
import coremltools as ct
import numpy as np

mlmodel = ct.models.MLModel("MobileFaceNet.mlpackage")

# 테스트 입력 (랜덤 얼굴 이미지 대신 numpy 배열)
test_input = np.random.randn(1, 3, 112, 112).astype(np.float32)

# PyTorch 원본 출력
with torch.no_grad():
    original_output = model(torch.tensor(test_input)).numpy()

# Core ML 출력 (Mac에서만 실행 가능)
# coreml_output = mlmodel.predict({"face_input": test_input})

# 비교: 두 출력의 최대 차이가 0.01 이하면 변환 성공
print(f"최대 오차: {np.max(np.abs(original_output - coreml_output)):.6f}")
```

---

## 7.3 Xcode 프로젝트 구조

```
FaceAuthApp/
├── Models/
│   └── MobileFaceNet.mlpackage        ← 변환된 모델
├── Services/
│   ├── CameraManager.swift            ← AVFoundation 카메라 관리
│   ├── FaceDetectionService.swift     ← Vision 얼굴 탐지
│   ├── FaceEmbeddingExtractor.swift   ← Core ML 추론
│   ├── EmbeddingDatabase.swift        ← GRDB 벡터 DB
│   └── BiometricDataVault.swift       ← Keychain 보안 저장
├── Pipeline/
│   └── FaceRecognitionPipeline.swift  ← 전체 파이프라인 오케스트레이터
├── UI/
│   ├── CameraPreviewView.swift        ← 카메라 프리뷰
│   ├── FaceGuideOverlay.swift         ← 얼굴 정렬 가이드
│   └── AttendanceResultView.swift     ← 출결 결과 표시
└── Networking/
    └── GroupwareAPIClient.swift       ← 그룹웨어 API 연동
```

---

## 7.4 전체 파이프라인 통합 (오케스트레이터)

```swift
actor FaceRecognitionPipeline {
    static let shared = FaceRecognitionPipeline()

    private let extractor = FaceEmbeddingExtractor()
    private let database = EmbeddingDatabase()
    private let apiClient = GroupwareAPIClient()

    func process(_ pixelBuffer: CVPixelBuffer) async {
        // Step 1: 얼굴 탐지
        guard let faceObservation = await detectFace(in: pixelBuffer) else { return }

        // Step 2: 얼굴 크롭 + 리사이즈
        guard let croppedBuffer = cropAndResize(
            pixelBuffer: pixelBuffer,
            boundingBox: faceObservation.boundingBox
        ) else { return }

        // Step 3: Liveness 체크 (선택적)
        guard await checkLiveness(faceObservation) else {
            await MainActor.run { showSpoofingAlert() }
            return
        }

        // Step 4: 임베딩 추출
        guard let embedding = extractor.extract(from: croppedBuffer) else { return }

        // Step 5: 유사도 상위 3명 검색
        let candidates = (try? database.findTopMatches(for: embedding, topK: 3)) ?? []
        guard !candidates.isEmpty else {
            await MainActor.run { showUnknownFaceUI() }
            return
        }

        // Step 6: 화면 하단에 후보 3명 이름 표시
        await MainActor.run { showCandidatesUI(candidates) }

        // Step 7: 1위 후보로 그룹웨어 출결 기록 (임계값 초과 시만)
        let best = candidates[0]
        guard best.score >= 0.6 else { return }
        await apiClient.recordAttendance(employeeId: best.id)
        await MainActor.run { showSuccessUI(employeeId: best.id, score: best.score) }
    }
}
```

---

## 7.5 성능 벤치마크 목표

| 단계 | 목표 지연 시간 | 측정 기준 기기 |
|---|---|---|
| 얼굴 탐지 (Vision) | < 10ms | iPhone 12 이상 |
| 얼굴 크롭 + 리사이즈 | < 5ms | iPhone 12 이상 |
| Core ML 추론 (ANE) | < 20ms | iPhone 12 이상 |
| 벡터 유사도 계산 (100명) | < 2ms | iPhone 12 이상 |
| **전체 파이프라인 (E2E)** | **< 50ms** | iPhone 12 이상 |

---

## 7.6 개발 체크리스트

### 모델 변환 단계
- [ ] Python 3.9~3.11 설치 확인
- [ ] `pip install torch coremltools` 성공
- [ ] MobileFaceNet `.pt` 파일 준비 (GitHub에서 다운로드)
- [ ] 모델 `eval()` 모드 전환 확인
- [ ] `FLOAT16` 양자화 변환 완료
- [ ] `.mlpackage` 파일 생성 및 크기 확인 (~9 MB)
- [ ] Mac으로 파일 전송

### Xcode 통합 단계
- [ ] `.mlpackage` 프로젝트에 추가
- [ ] 자동 생성된 Swift 클래스 컴파일 성공
- [ ] `computeUnits = .all` 설정
- [ ] 카메라 권한 `Info.plist` 추가 (`NSCameraUsageDescription`)
- [ ] 실기기 빌드 테스트 (시뮬레이터는 카메라 미지원)

### 보안 단계
- [ ] Keychain 암호화 키 저장 구현
- [ ] `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` 설정
- [ ] 그룹웨어 API Certificate Pinning 적용
- [ ] Jailbreak 탐지 로직 추가 (선택)
