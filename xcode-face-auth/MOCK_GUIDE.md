# 🎮 목업 앱 사용 가이드

## 📱 현재 구현된 기능 (모델 없이 작동)

### ✅ **완전히 작동하는 것**
1. **카메라 시스템**
   - 실제 AVFoundation 전면 카메라 스트림
   - 카메라 권한 관리 (요청/허용/거부)
   - UIKit → SwiftUI 브릿지

2. **얼굴 인식 시뮬레이션**
   - 2초마다 자동으로 얼굴 감지 (70% 확률)
   - 8명의 목업 사원 데이터베이스
   - **실제 Accelerate 프레임워크** 사용:
     * 128차원 벡터 생성
     * `vDSP_dotpr` - 내적 계산
     * `vDSP_svesq` - 벡터 크기 계산
     * 코사인 유사도 알고리즘 (실제 구현과 동일)
   - 유사도 상위 3명 표시 (최소 30% 이상)

3. **AR 오버레이 UI**
   - ✅ 녹색 얼굴 감지 프레임 (중앙)
   - ✅ 상태 배지 (얼굴 감지됨 / 찾는 중...)
   - ✅ 사원 정보 카드:
     * 이름 첫 글자 아바타
     * 이름 + 부서
     * 유사도 % (색상 변화: 70%↑녹색, 50~70% 주황, 50%↓ 빨강)
   - ✅ 애니메이션 (슬라이드업, 페이드)

4. **출석 체크 플로우**
   - 사원 카드 클릭
   - 확인 다이얼로그 ("김철수님의 출석을 체크하시겠습니까?")
   - 콘솔 로그 출력: `✅ 출석 체크: 김철수 (개발팀)`

---

## 🚀 실행 방법

### 1. 프로젝트 열기
```bash
# Xcode에서 .xcodeproj 파일 열기
```

### 2. 빌드 타겟 선택
- **추천**: 실제 iPhone (카메라 스트림 확인 가능)
- **가능**: 시뮬레이터 (UI만 확인, 카메라는 검은 화면)

### 3. 실행 (⌘R)

### 4. 사용 시나리오
1. 앱 시작 → "카메라 권한 요청" 버튼 클릭
2. 시스템 권한 허용
3. "카메라 열기" 버튼 클릭
4. 카메라 화면 진입:
   - 상단 왼쪽: 상태 배지 (빨간불 → 녹색불 반복)
   - 상단 오른쪽: X 닫기 버튼
   - 중앙: 녹색 얼굴 프레임 (감지시 나타남)
   - 하단: 사원 목록 카드 (감지시 슬라이드업)
5. 사원 카드 클릭 → 출석 확인 다이얼로그
6. "확인" → 콘솔 로그 확인 + 화면 닫힘

---

## 🎭 목업 사원 데이터

| 이름 | 부서 | 벡터 |
|------|------|------|
| 김철수 | 개발팀 | 128차원 랜덤 |
| 이영희 | 디자인팀 | 128차원 랜덤 |
| 박민수 | 기획팀 | 128차원 랜덤 |
| 정수진 | 마케팅팀 | 128차원 랜덤 |
| 최지훈 | 개발팀 | 128차원 랜덤 |
| 강민지 | 인사팀 | 128차원 랜덤 |
| 윤서연 | 개발팀 | 128차원 랜덤 |
| 한동욱 | 영업팀 | 128차원 랜덤 |

> **참고**: 매번 실행마다 벡터가 다시 생성되므로 유사도는 랜덤입니다.

---

## 🔧 핵심 구현 코드 위치

### 파일 구조
```
FaceAuthApp/
├── ContentView.swift          # 메인 화면 (권한 관리)
├── FaceRecognitionView.swift  # 카메라 + AR 오버레이
├── FaceRecognitionManager.swift # 얼굴 인식 로직 (목업 + 실제 Accelerate)
├── Employee.swift             # 사원 모델 + 목업 데이터
├── CameraView.swift           # SwiftUI → UIKit 브릿지
└── CameraViewController.swift # AVFoundation 카메라
```

### 실제 알고리즘 구현 (목업 아님!)

**FaceRecognitionManager.swift: cosineSimilarity()**
```swift
private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    var dot: Float = 0
    var normA: Float = 0
    var normB: Float = 0
    
    // Accelerate 프레임워크 사용 (실제 프로덕션 코드와 동일)
    vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
    vDSP_svesq(a, 1, &normA, vDSP_Length(a.count))
    vDSP_svesq(b, 1, &normB, vDSP_Length(b.count))
    
    let denominator = sqrt(normA) * sqrt(normB)
    return dot / denominator
}
```

---

## 🔄 실제 모델 통합 로드맵

### Phase 1: Vision 통합
**교체**: `FaceRecognitionManager.startSimulation()`
```swift
// Before (목업)
Timer.scheduledTimer(...)

// After (실제)
let output = AVCaptureVideoDataOutput()
output.setSampleBufferDelegate(self, ...)
captureSession.addOutput(output)
```

### Phase 2: Core ML 통합
**추가**: MobileFaceNet.mlmodel
```swift
// Before (목업)
let currentVector = generateRandomVector()

// After (실제)
let model = try MobileFaceNet(configuration: MLModelConfiguration())
let output = try model.prediction(input: faceImage)
let currentVector = output.featureVector
```

### Phase 3: GRDB 통합
**교체**: `Employee.mockEmployees`
```swift
// Before (목업)
private let employees = Employee.mockEmployees

// After (실제)
private let dbQueue = DatabaseQueue(...)
let employees = try dbQueue.read { db in
    try Employee.fetchAll(db)
}
```

### Phase 4: 그룹웨어 API
**교체**: `checkAttendance()`
```swift
// Before (목업)
print("✅ 출석 체크: \(employee.name)")

// After (실제)
await attendanceAPI.post(employeeId: employee.id)
```

---

## 🐛 트러블슈팅

### 문제: 카메라 검은 화면
- **원인**: 시뮬레이터 사용 중
- **해결**: 실제 디바이스에서 실행

### 문제: 사원 목록이 안 나타남
- **원인**: 유사도가 30% 미만
- **해결**: 
  - 2초 대기 (다음 감지 주기)
  - 또는 `FaceRecognitionManager.swift:77` 에서 `.filter { $0.confidence > 0.3 }` → `0.1`로 변경

### 문제: 콘솔 로그가 안 보임
- **해결**: Xcode → View → Debug Area → Activate Console (⌘⇧C)

---

## 📊 성능 측정

### Accelerate 연산 성능
- **벡터 차원**: 128 Float
- **비교 대상**: 8명
- **예상 시간**: < 1ms (iPhone 12 이상)

### 실제 모델 추가시 예상
- **Vision 얼굴 감지**: ~15ms/frame
- **Core ML 추론**: ~50ms/face
- **GRDB 조회**: ~5ms
- **전체 파이프라인**: ~70ms (60fps 달성 가능)

---

## 📝 다음 단계 체크리스트

- [ ] MobileFaceNet 모델 변환 (.mlmodel)
- [ ] Vision 프레임워크 통합
- [ ] GRDB 설치 및 마이그레이션
- [ ] 실제 사원 등록 UI
- [ ] TrueDepth 위조 방지
- [ ] 그룹웨어 API 연동
- [ ] 에러 핸들링 및 로깅
