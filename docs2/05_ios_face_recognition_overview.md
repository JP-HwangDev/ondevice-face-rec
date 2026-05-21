# 05. 사내 그룹웨어 연동형 iOS 온디바이스 얼굴인식 시스템 — 개요

> 모든 AI 추론을 서버 없이 기기(iPhone) 내부에서 수행하는 프라이버시 우선 출입 인증 시스템

---

## 5.1 시스템 목표 (Goals)

| 항목 | 목표 |
|---|---|
| **처리 위치** | 100% 온디바이스 (On-device) — 서버 전송 없음 |
| **인식 방식** | 얼굴 임베딩 벡터 기반 1:N 식별 (Identification) |
| **보안** | 생체 데이터 기기 내 암호화 저장 (Keychain / Encrypted CoreData) |
| **연동** | 기존 그룹웨어(비밀번호 출석) → 얼굴인식 방식으로 대체 연동 |
| **플랫폼** | iOS 전용 (Swift) |
| **앱 실행 방식** | 항시 켜진 상태 (카메라 상시 활성) |
| **UI 인터랙션** | 얼굴 감지 → 하단에 유사도 상위 3명 이름 표시 → 이름 탭 → 출석체크 |

---

## 5.2 핵심 개념 — 얼굴 임베딩 (Face Embedding)

얼굴 인식은 "이 사람이 누구인가?"를 이미지로 직접 비교하는 것이 아닙니다.

```
[얼굴 이미지]
      ↓ (MobileFaceNet 모델 통과)
[512차원 숫자 벡터 — Embedding]
예: [0.12, -0.87, 0.34, ..., 0.91]  ← 512개 숫자

[비교]
등록된 홍길동 벡터 vs 현재 입력 벡터
→ Cosine Similarity 또는 Euclidean Distance 계산
→ 임계값(Threshold) 이내: 동일 인물 판정
```

### 유사도 계산 방식 비교

| 방식 | 공식 | 범위 | 임계값 예시 | 특징 |
|---|---|---|---|---|
| **Cosine Similarity** | A·B / (‖A‖ × ‖B‖) | -1 ~ 1 | ≥ 0.6 이면 동일 인물 | 벡터 크기 무관, 방향만 비교 |
| **Euclidean Distance** | √Σ(aᵢ-bᵢ)² | 0 ~ ∞ | ≤ 1.1 이면 동일 인물 | 직관적, 정규화 필수 |

---

## 5.3 전체 시스템 아키텍처

```
┌────────────────────────────────────────────────────────┐
│                    iPhone (On-device)                  │
│                                                        │
│  [TrueDepth 카메라] ─────────────────────────────────┐ │
│        ↓ CMSampleBuffer                              │ │
│  [AVFoundation]                                      │ │
│        ↓ 얼굴 영역 탐지                               │ │
│  [Vision Framework (VNDetectFaceRectanglesRequest)]  │ │
│        ↓ Crop + Resize (112×112)                     │ │
│  [Core ML (MobileFaceNet.mlpackage)]                 │ │
│        ↓ 512차원 Embedding 벡터                       │ │
│  [Accelerate Framework (vDSP/SIMD 유사도 계산)]       │ │
│        ↓ 비교 결과                                    │ │
│  [GRDB.swift / SQLite (직원 벡터 DB)]                │ │
│        ↓ 인물 ID + 신뢰도                             │ │
│  [비즈니스 로직 (출결 처리)]                           │ │
│        ↓                                             │ │
│  [그룹웨어 API 연동 (HTTP 출결 기록)]                  │ │
│        ↓                                             │ │
│  [SwiftUI — 결과 UI 표시]         ← [Liveness Check] │ │
└────────────────────────────────────────────────────────┘
```

---

## 5.4 UI 인터랙션 흐름

```
[카메라 항시 활성 — 앱 실행 중 상시 동작]
      ↓
[얼굴 감지됨]
      ↓
[유사도 상위 3명 계산]
      ↓
┌─────────────────────────────┐
│  화면 하단 후보 표시         │
│  ┌──────┐ ┌──────┐ ┌──────┐│
│  │홍길동│ │김철수│ │박영희││  ← 유사도 순
│  │ 94% │ │ 81% │ │ 73% ││
│  └──────┘ └──────┘ └──────┘│
└─────────────────────────────┘
      ↓ (사용자가 자신의 이름 탭)
[그룹웨어 API 호출 → 출석 처리]
      ↓
[완료 피드백 UI 표시]
```

**설계 포인트:**
- 자동 확정 없음 — 반드시 본인이 직접 탭해야 출석 처리됨 (오인식 방지)
- 임계값(0.6) 미만인 후보는 목록에서 제외
- 탭 후 일정 시간(예: 3초) 동안 중복 인식 방지 처리 필요

---

## 5.5 핵심 지식 우선순위 (Core Competencies)

| 우선도 | 항목 | 실무 이유 | Swift/iOS 기술 스택 |
|---|---|---|---|
| ★★★★★ | **카메라 데이터 스트림 처리** | 정적 사진이 아닌 실시간 비디오 프레임 처리 필수 | `AVFoundation`, `AVCaptureVideoDataOutput`, `CMSampleBuffer` |
| ★★★★★ | **Core ML & Vision 파이프라인** | 이미지 Orientation/Resize 처리 실패 시 인식률 0% | `Vision Framework (VNCoreMLRequest)`, `Core ML` |
| ★★★★★ | **얼굴 임베딩 (Face Embedding)** | "누구인가?"의 실체는 벡터 간 거리 계산 | `MobileFaceNet`, `Cosine Similarity` |
| ★★★★★ | **비동기/동시성 프로그래밍** | AI 추론을 메인 스레드에서 실행하면 UI 멈춤 | `Swift Concurrency (async/await)`, `GCD (DispatchQueue)` |
| ★★★★ | **데이터 보안 (Keychain/Sandbox)** | 얼굴 벡터는 생체 개인정보 — 암호화 저장 필수 | `Keychain Services`, `CryptoKit`, `File Protection` |

---

## 5.6 고급 최적화 항목 (Advanced)

| 우선도 | 항목 | 실무 이유 | 기술 스택 |
|---|---|---|---|
| ★★★ | **Liveness Detection (생체 감지)** | 사진 스푸핑 방지 (출입 보안의 핵심 취약점) | `ARKit (TrueDepth)`, `Vision (Face Landmarks)` |
| ★★★ | **모델 양자화 (Quantization)** | 기기 발열·배터리 최적화 | `Core ML Tools (Python)`, `Float16` |
| ★★ | **온디바이스 벡터 DB** | 직원 수백 명 초과 시 검색 성능 최적화 | `SQLite + KD-Tree`, `Realm Local` |
| ★★ | **UI 피드백 및 가이드** | 얼굴 정렬 가이드가 인식률 2배 향상 | `SwiftUI (ZStack, Path)`, `Vision BoundingBox` |

---

## 5.7 얼굴 등록(Enrollment) 전략

```
[등록 방식 선택]
├─ 직원 본인이 앱에서 셀카 촬영 (자율 등록)
└─ 관리자 일괄 업로드 (HR 시스템 연동)

[촬영 권장 사항]
├─ 정면 / 좌 30° / 우 30° 최소 3각도 촬영
├─ 각도별 임베딩 벡터 추출
└─ 다각도 벡터의 가중 평균(Weighted Average) → 대표 벡터 생성

[저장]
└─ 대표 벡터 → Keychain 또는 Encrypted SQLite에 보안 저장
```

---

## 5.8 보안 고려사항

| 위협 | 대응 방법 |
|---|---|
| **사진 스푸핑** | Liveness Detection (눈 깜빡임, TrueDepth Depth 데이터) |
| **데이터 유출** | Keychain 암호화 저장, File Protection Complete |
| **중간자 공격** | 그룹웨어 API 통신 시 TLS 1.3 + Certificate Pinning |
| **역공학 (앱 분석)** | 모델 파일 암호화, Jailbreak 탐지 로직 추가 |
| **벡터 도난** | 벡터만으로 원본 얼굴 복원 불가 (단방향 변환) |
