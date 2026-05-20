# FaceAuth App 🔐

**사내 그룹웨어 출석체크 자동화를 위한 실시간 얼굴 인식 앱**

## 📱 핵심 기능
- ✅ 실시간 얼굴 감지 + 포착시 유사도 높은 3명의 사원 이름 표시
- ✅ 온디바이스 얼굴 인식 (서버 전송 없음)
- ✅ TrueDepth 위조 방지 (평면 사진 감지)
- ✅ 터치 한 번으로 출석 체크 완료

## 🛠 기술 스택
| 구분 | 기술 | 역할 |
|------|------|------|
| **언어** | Swift 5.x+ | 앱 개발 |
| **UI** | SwiftUI | 화면 및 AR 오버레이 |
| **카메라** | AVFoundation | 실시간 프레임 처리 |
| **얼굴 감지** | Vision | 얼굴 위치 탐지 |
| **얼굴 인식** | Core ML | MobileFaceNet 모델 |
| **위조 방지** | TrueDepth | Depth 데이터 분석 |
| **DB** | GRDB.swift | 벡터 데이터 저장 |
| **고속 연산** | Accelerate | 벡터 유사도 계산 |

**최소 지원**: iOS 17.0+

## 📂 프로젝트 구조
```
FaceAuthApp/
├── FaceAuthApp.swift              # 앱 진입점
├── ContentView.swift              # 메인 화면 (탭 뷰)
├── FaceRecognitionView.swift      # 카메라 + AR 오버레이
├── FaceRecognitionManager.swift   # 얼굴 인식 로직 (Vision + Core ML)
├── FaceEmbeddingExtractor.swift   # MobileFaceNet Core ML 추론
├── Employee.swift                 # 사원 모델 + FaceMatch
├── EmployeeStore.swift            # 사원 데이터 저장소 (UserDefaults)
├── EmployeeManagementView.swift   # 사원 관리 화면
├── AddEmployeeView.swift          # 멀티앵글 얼굴 등록
├── CameraView.swift               # SwiftUI → UIKit 브릿지
├── CameraViewController.swift     # AVFoundation + Vision
├── Models/
│   └── MobileFaceNet.mlpackage    # ← 여기에 모델 추가!
└── docs/
    └── ai_context/                # 🤖 AI 어시스턴트용 문서
```

## 🚀 실행 방법
1. Xcode에서 프로젝트 열기
2. **실제 디바이스** 선택 (카메라 기능)
3. Command + R로 실행
4. 카메라 권한 허용
5. "카메라 열기" 버튼 클릭
6. 얼굴 감지 시뮬레이션 확인 (2초마다)
7. 하단에 나타나는 사원 카드 클릭 → 출석 체크

> ⚠️ 시뮬레이터에서도 UI는 작동하지만 카메라는 검은 화면이 나옵니다.

## 📝 개발 로드맵

### Phase 1: 기본 인프라 ✅
- [x] AVFoundation 카메라 연동
- [x] SwiftUI + UIKit 하이브리드 구조
- [x] 카메라 권한 관리

### Phase 2: 얼굴 처리 파이프라인 ✅
- [x] Vision으로 얼굴 감지 ✅ **실제 구현됨**
- [x] Core ML 모델 통합 ✅ **MobileFaceNet 지원**
- [x] 사원 데이터 저장소 (UserDefaults 영속 저장)
- [x] Accelerate 유사도 계산 ✅ **실제 구현됨**

### Phase 3: AR UI 및 인증 ✅
- [x] SwiftUI ZStack AR 오버레이
- [x] 실시간 이름 표시 (상위 3명 + 유사도 %)
- [x] 터치 인증 로직
- [x] 멀티앵글 얼굴 등록 (Face ID 스타일)
- [ ] TrueDepth 위조 방지 (추후 추가)

### Phase 4: 그룹웨어 연동
- [ ] 출석 API 연동
- [ ] 로컬 출석 로그
- [ ] 에러 핸들링

---

## 🎮 **현재 버전 기능**

### ✅ **완전히 작동하는 기능**
1. **카메라 시스템**
   - 실제 AVFoundation 전면 카메라 스트림
   - 카메라 권한 관리 (요청/허용/거부)
   - UIKit → SwiftUI 브릿지

2. **Vision 얼굴 감지**
   - `VNDetectFaceRectanglesRequest` 실시간 얼굴 감지
   - 복수 얼굴 동시 감지 지원
   - 얼굴 위치 AR 오버레이 표시

3. **Core ML MobileFaceNet 통합**
   - 모델 자동 감지 (있으면 사용, 없으면 목업 모드)
   - 128차원/512차원 임베딩 벡터 추출
   - L2 정규화된 벡터 출력
   - ANE(Apple Neural Engine) 가속 지원

4. **얼굴 인식 및 매칭**
   - **실제 Accelerate 프레임워크** 사용:
     * `vDSP_dotpr` - 내적 계산
     * `vDSP_svesq` - 벡터 크기 계산
     * 코사인 유사도 알고리즘
   - 유사도 상위 3명 표시 (30% 이상만)
   - 멀티 벡터 비교 (등록 시 여러 각도 지원)

5. **사원 관리**
   - UserDefaults 영속 저장
   - 부서별 필터링
   - 검색 기능
   - 멀티앵글 얼굴 등록 (Face ID 스타일 5방향)

6. **AR UI 오버레이**
   - 녹색 얼굴 감지 프레임 (Vision 좌표 기반)
   - 상태 배지 (모델 로드 상태 표시)
   - 사원 정보 카드 (이름, 부서, 유사도 %)
   - 애니메이션 (슬라이드업, 페이드)

7. **출석 체크**: 사원 카드 클릭 → 확인 다이얼로그 → 콘솔 로그

### 🔧 **모델 추가 방법**
1. `MobileFaceNet.mlpackage` 파일을 Xcode 프로젝트에 드래그
2. "Copy items if needed" 체크
3. 빌드 → 자동으로 모델 감지 및 사용

---

## 📚 문서
상세한 기획 및 기술 문서는 [`docs/ai_context/`](docs/ai_context/) 폴더를 참조하세요.

## 🔒 개인정보 보호
- 모든 얼굴 인식 처리는 **온디바이스**에서 수행
- 얼굴 이미지 미저장, 특징 벡터만 로컬 DB에 저장
- 서버 전송 없음

