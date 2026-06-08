# UI/UX 설계

## 화면 구조

### 메인 화면 (실시간 인식)
SwiftUI + AVFoundation 하이브리드 구조

```
┌─────────────────────────┐
│   [Camera Preview]      │ ← AVCaptureVideoPreviewLayer (UIKit)
│                         │
│                         │
│                         │ ← AR 오버레이 (SwiftUI ZStack)
│                         │   터치 가능한 사용자 이름 박스
│                         │
│  ┌───────────────────┐  │
│  │  임사원● 박사원● 김사원● │  │
│  └───────────────────┘  │
│                         │
│  [등록] [설정]          │ ← 하단 버튼
└─────────────────────────┘
```

## 주요 컴포넌트

### 1. CameraView (SwiftUI)
```swift
struct CameraView: View {
    @StateObject var viewModel: CameraViewModel
    
    var body: some View {
        ZStack {
            // UIKit 카메라 프리뷰
            CameraPreviewRepresentable(session: viewModel.captureSession)
            
            // AR 오버레이: 감지된 얼굴 위에 이름 표시
            ForEach(viewModel.detectedFaces) { face in
                FaceNameBoxView(face: face)
                    .position(face.position)
                    .onTapGesture {
                        viewModel.authenticate(face: face)
                    }
            }
            
            // 하단 버튼
            VStack {
                Spacer()
                HStack {
                    Button("등록") { viewModel.showRegistration = true }
                    Button("설정") { viewModel.showSettings = true }
                }
                .padding()
            }
        }
    }
}
```

### 2. FaceNameBoxView (AR 오버레이)
```swift
struct FaceNameBoxView: View {
    let face: DetectedFace
    
    var body: some View {
        VStack {
            Text(face.name)
                .font(.headline)
                .foregroundColor(.white)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(face.isAuthenticated ? Color.green.opacity(0.8) : Color.blue.opacity(0.8))
                        .shadow(radius: 4)
                )
            
            // 신뢰도 표시 (선택)
            Text("\(Int(face.confidence * 100))%")
                .font(.caption)
                .foregroundColor(.white.opacity(0.8))
        }
    }
}
```

### 3. 등록 화면 (선택)
```
┌─────────────────────────┐
│   얼굴 등록             │
├─────────────────────────┤
│   [Camera Preview]      │
│                         │
│    얼굴을 화면 중앙에    │
│    위치시켜 주세요      │
│                         │
│   ┌─────────────────┐   │
│   │  이름 입력      │   │
│   └─────────────────┘   │
│                         │
│   [촬영 및 등록]        │
└─────────────────────────┘
```

## 사용자 플로우

### 1. 실시간 인식 플로우
```
앱 실행 → 카메라 권한 확인 → 카메라 켜기
    ↓
얼굴 감지 (Vision)
    ↓
특징 추출 (Core ML)
    ↓
벡터 비교 (Accelerate + GRDB)
    ↓
매칭 성공? 
    YES → 이름 박스 표시 (터치 가능)
    NO → 박스 표시 안 함
    ↓
사용자 터치
    ↓
위조 검사 (TrueDepth)
    ↓
그룹웨어 출석 체크
    ↓
성공 피드백 (녹색 박스 + 햅틱)
```

### 2. 등록 플로우
```
[등록] 버튼 터치
    ↓
카메라 표시, 얼굴 중앙 정렬 가이드, 얼굴 돌려서 촬영
    ↓
이름 입력 시트
    ↓
특징 추출 (Core ML)
    ↓
GRDB에 저장
    ↓
완료 알림
```

## UI 가이드라인

### 색상
- **감지됨 (미인증)**: 파란색 박스 (`Color.blue.opacity(0.8)`)
- **인증 성공**: 녹색 박스 (`Color.green.opacity(0.8)`)
- **인증 실패**: 빨간색 박스 (`Color.red.opacity(0.8)`)

### 애니메이션
- 박스 등장: `scaleEffect` + `animation(.spring())`
- 인증 성공: `withAnimation` + 햅틱 피드백
- 전환: `transition(.opacity)`

### 접근성
- 얼굴 박스에 VoiceOver 레이블 추가
- Dynamic Type 지원
- 고대비 모드 지원

## 기술적 구현

### AVFoundation → SwiftUI 브릿지
```swift
struct CameraPreviewRepresentable: UIViewControllerRepresentable {
    let session: AVCaptureSession
    
    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.captureSession = session
        return controller
    }
    
    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}
```

### 좌표 변환 (Vision → SwiftUI)
Vision의 정규화된 좌표(0~1)를 SwiftUI 뷰 좌표로 변환
```swift
func convertVisionToViewCoordinate(_ rect: CGRect, viewSize: CGSize) -> CGPoint {
    let x = rect.midX * viewSize.width
    let y = (1 - rect.midY) * viewSize.height // Vision은 Y축이 반대
    return CGPoint(x: x, y: y)
}
```

## 권한 처리

### 카메라 권한
- 첫 실행 시 권한 요청 (`AVCaptureDevice.requestAccess`)
- 거부 시 설정 앱으로 유도하는 알림 표시

### Info.plist 설정
```xml
<key>NSCameraUsageDescription</key>
<string>출석 체크를 위해 얼굴 인식이 필요합니다.</string>
```
