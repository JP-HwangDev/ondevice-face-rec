# 기술 스택

## 필수 기술 (강제 사항)

| 구분 | 기술/도구 | 역할 |
|------|----------|------|
| **언어** | Swift 5.x+ | 앱 개발 메인 언어 |
| **UI 프레임워크** | SwiftUI | 화면 구성, ZStack으로 카메라 위 AR 오버레이 |
| **카메라 제어** | AVFoundation | 카메라 제어 및 프레임 데이터 추출 (`AVCaptureVideoDataOutput`) |
| **얼굴 감지** | Vision | 카메라 영상에서 얼굴 위치 고속 탐지 (`VNDetectFaceRectanglesRequest`) |
| **얼굴 인식** | Core ML | MobileFaceNet 모델(.mlpackage)로 얼굴 식별 |
| **모델 파일** | MobileFaceNet | Core ML 형식으로 변환된 AI 모델 |
| **위조 방지** | TrueDepth (Depth) | 평면 사진 vs 실제 입체 얼굴 판별 (`AVCaptureDepthDataOutput`) |
| **데이터 저장** | GRDB.swift | 얼굴 특징 벡터를 SQLite 기반으로 저장 |
| **고속 연산** | Accelerate (vDSP) | 벡터 유사도 계산 (`simd_dot` 등) |

## 기술 세부사항

### 카메라 처리
- `AVCaptureVideoDataOutput`: 실시간 프레임 데이터 추출
- `AVCaptureDepthDataOutput`: TrueDepth 데이터 (Face ID 지원 기기)

### 얼굴 처리 파이프라인
1. **감지**: Vision framework로 얼굴 위치(바운딩 박스) 탐지
2. **특징 추출**: Core ML로 얼굴 특징 벡터(128~512차원) 추출
3. **비교**: Accelerate로 저장된 벡터와 유사도 계산
4. **매칭**: 임계값 이상이면 해당 사용자로 식별

### 데이터 저장
- **GRDB.swift**: SQLite 래퍼
- 벡터 데이터를 `Data` 타입으로 직렬화하여 저장
- 테이블 구조: 사용자 ID, 이름, 얼굴 특징 벡터, 등록일

### 성능 최적화
- Vision: 얼굴 감지만 수행 (랜드마크 불필요)
- Accelerate: SIMD 연산으로 벡터 비교 0.001초 이내
- Core ML: 온디바이스 추론으로 서버 통신 없음

## 최소 지원 버전
- iOS 17.0+
- Face ID 지원 기기 권장 (TrueDepth 위조 방지)
