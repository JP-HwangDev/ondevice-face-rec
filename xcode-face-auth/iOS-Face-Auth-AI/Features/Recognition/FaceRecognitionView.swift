//
//  FaceRecognitionView.swift
//  FaceAuthApp
//
//  Created by yon on 2026/02/01.
//


import SwiftUI
import Vision


/// 얼굴 인식 메인 화면 (카메라 + AR 오버레이)
struct FaceRecognitionView: View {
    @StateObject private var recognitionManager = FaceRecognitionManager()
    @Environment(\.dismiss) private var dismiss
    @State private var selectedEmployee: Employee?
    @State private var showAttendanceConfirm = false
    @State private var showResultToast = false
    @State private var resultToastMessage = ""
    @State private var resultToastSuccess = true


    @AppStorage("auto_dismiss_camera") private var autoDismissCamera = true

    /// 카메라 이미지 크기 (Vision 좌표 → 화면 좌표 변환에 필요)
    @State private var cameraImageSize: CGSize = .zero

    /// 랜드마크 포함 observations (bbox 그리기용)
    @State private var landmarkObservations: [VNFaceObservation] = []

    var body: some View {
        ZStack {
            // 카메라 프리뷰 + Vision 얼굴 감지
            CameraView(
                onFaceDetected: { observations, pixelBuffer in
                    // FaceRectangles rev3 결과 (yaw/pitch 포함) → 인식 처리용
                    recognitionManager.processFaceObservations(observations, pixelBuffer: pixelBuffer)
                },
                onLandmarksDetected: { observations in
                    // Landmarks 결과 → 정확한 bbox 그리기용
                    landmarkObservations = observations
                },
                onImageSizeDetected: { size in
                    // 픽셀 버퍼는 카메라 네이티브(가로), Vision은 .leftMirrored로 세로 처리
                    cameraImageSize = CGSize(width: size.height, height: size.width)
                    DebugLogger.shared.log(category: .faceAuth, message: "카메라 이미지 크기", details: "원본: \(Int(size.width))x\(Int(size.height)), Vision: \(Int(size.height))x\(Int(size.width))")
                }
            )
            .ignoresSafeArea()
            .onAppear {
                DebugLogger.shared.log(category: .faceAuth, message: "얼굴 인식 카메라 화면 열림", details: "등록 사원: \(EmployeeStore.shared.employees.count)명, 모델: \(recognitionManager.modelStatus)")
            }
            .onDisappear {
                DebugLogger.shared.log(category: .faceAuth, message: "얼굴 인식 카메라 화면 닫힘")
            }

            // 전체 화면 바운딩 박스 오버레이 (랜드마크 기반 + aspectFill 보정)
            GeometryReader { geometry in
                ForEach(Array(landmarkObservations.enumerated()), id: \.offset) { index, observation in
                    let faceRect = visionFaceToScreen(observation, in: geometry.size)
                    let matchColor: Color = recognitionManager.detectedMatches.isEmpty ? .blue : .green

                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(matchColor, lineWidth: 3)
                        .frame(width: faceRect.width, height: faceRect.height)
                        .position(x: faceRect.midX, y: faceRect.midY)
                        .overlay(
                            Group {
                                if let topMatch = recognitionManager.detectedMatches.first {
                                    Text("\(topMatch.employee.name) \(topMatch.confidencePercent)%")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(matchColor.opacity(0.8))
                                        .cornerRadius(4)
                                        .position(x: faceRect.midX, y: faceRect.minY - 16)
                                } else {
                                    Text("얼굴 #\(index + 1)")
                                        .font(.caption)
                                        .fontWeight(.bold)
                                        .foregroundStyle(.white)
                                        .padding(4)
                                        .background(matchColor.opacity(0.8))
                                        .cornerRadius(4)
                                        .position(x: faceRect.midX, y: faceRect.minY - 16)
                                }
                            }
                        )
                }
            }
            .ignoresSafeArea()

            // UI 오버레이
            VStack {
                HStack {
                    statusBadge
                    Spacer()
                    closeButton
                }
                .padding()

                Spacer()

                // 하단: 매칭된 사원 목록
                if !recognitionManager.detectedMatches.isEmpty {
                    matchedEmployeesList
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut, value: recognitionManager.isFaceDetected)
            .animation(.easeInOut, value: recognitionManager.detectedMatches.count)


            // 출석 결과 토스트
            if showResultToast {
                resultToastView
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(100)
            }
        }
        .confirmationDialog("출석 유형 선택", isPresented: $showAttendanceConfirm, titleVisibility: .visible) {
            Button("출근 체크") {
                if let employee = selectedEmployee {
                    DebugLogger.shared.log(category: .faceAuth, message: "출근 체크 선택: \(employee.name)")
                    performAttendance(employee: employee, type: .checkIn)
                }
            }
            Button("퇴근 체크") {
                if let employee = selectedEmployee {
                    DebugLogger.shared.log(category: .faceAuth, message: "퇴근 체크 선택: \(employee.name)")
                    performAttendance(employee: employee, type: .checkOut)
                }
            }
            Button("취소", role: .cancel) {
                DebugLogger.shared.log(category: .faceAuth, message: "출석 다이얼로그 취소")
            }
        } message: {
            if let employee = selectedEmployee {
                let alreadyIn = AttendanceStore.shared.hasCheckedInToday(employeeId: employee.id)
                if alreadyIn {
                    Text("\(employee.name)님은 이미 오늘 출근 체크가 되어있습니다.\n퇴근 체크를 하시겠습니까?")
                } else {
                    Text("\(employee.name)님의 출석을 체크합니다.")
                }
            }
        }
    }


    // MARK: - Vision 랜드마크 → 화면 좌표 변환 (aspectFill 보정)

    /// VNFaceObservation의 랜드마크(턱선/눈썹 등)로 정확한 얼굴 영역을 계산하고
    /// 화면 좌표(좌상단 원점)로 변환. resizeAspectFill 스케일링/크롭 반영.
    private func visionFaceToScreen(_ observation: VNFaceObservation, in viewSize: CGSize) -> CGRect {
        // 랜드마크에서 얼굴 전체를 감싸는 정규화된 bbox 계산
        let normalizedRect = landmarkBoundingRect(for: observation)
        return normalizedRectToScreen(normalizedRect, in: viewSize)
    }

    /// 랜드마크 포인트들로부터 얼굴 전체를 감싸는 정규화된 rect 계산
    private func landmarkBoundingRect(for observation: VNFaceObservation) -> CGRect {
        let bbox = observation.boundingBox

        guard let landmarks = observation.landmarks else {
            // 랜드마크 없으면 bbox + 마진 폴백
            return expandedBBox(bbox)
        }

        // 모든 랜드마크 포인트를 이미지 정규화 좌표로 수집
        var allPoints: [CGPoint] = []

        let regions: [VNFaceLandmarkRegion2D?] = [
            landmarks.faceContour,       // 턱선 (귀~턱~귀)
            landmarks.leftEyebrow,       // 왼쪽 눈썹
            landmarks.rightEyebrow,      // 오른쪽 눈썹
            landmarks.noseCrest,         // 코 능선
            landmarks.nose,              // 코
            landmarks.outerLips,         // 입술 외곽
            landmarks.leftEye,           // 왼쪽 눈
            landmarks.rightEye,          // 오른쪽 눈
        ]

        for region in regions {
            guard let region = region else { continue }
            let points = region.normalizedPoints
            for pt in points {
                // 랜드마크 포인트는 bbox 기준 상대좌표(0~1) → 이미지 절대좌표로 변환
                let absX = bbox.origin.x + pt.x * bbox.width
                let absY = bbox.origin.y + pt.y * bbox.height
                allPoints.append(CGPoint(x: absX, y: absY))
            }
        }

        guard !allPoints.isEmpty else {
            return expandedBBox(bbox)
        }

        // 랜드마크 포인트들의 바운딩 박스
        let minX = allPoints.map(\.x).min()!
        let maxX = allPoints.map(\.x).max()!
        let minY = allPoints.map(\.y).min()!
        let maxY = allPoints.map(\.y).max()!

        let landmarkW = maxX - minX
        let landmarkH = maxY - minY

        // 이마 마진: 눈썹 위쪽은 랜드마크가 없으므로 눈썹~턱 높이의 25% 추가
        let foreheadMargin = landmarkH * 0.25
        // 좌우/아래 약간의 여유
        let sideMargin = landmarkW * 0.08
        let bottomMargin = landmarkH * 0.05

        return CGRect(
            x: minX - sideMargin,
            y: minY - bottomMargin,        // Vision Y: 아래가 0, 위가 1 → minY가 턱
            width: landmarkW + sideMargin * 2,
            height: landmarkH + foreheadMargin + bottomMargin
        )
    }

    /// 랜드마크 없을 때 폴백: bbox에 마진 추가
    private func expandedBBox(_ bbox: CGRect) -> CGRect {
        let marginX = bbox.width * 0.15
        let marginTop = bbox.height * 0.40
        let marginBottom = bbox.height * 0.30
        return CGRect(
            x: bbox.origin.x - marginX,
            y: bbox.origin.y - marginBottom,
            width: bbox.width + marginX * 2,
            height: bbox.height + marginTop + marginBottom
        )
    }

    /// 정규화된 rect(0~1, 좌하단 원점) → 화면 좌표(좌상단 원점) 변환
    private func normalizedRectToScreen(_ rect: CGRect, in viewSize: CGSize) -> CGRect {
        guard cameraImageSize.width > 0, cameraImageSize.height > 0 else {
            let r = VNImageRectForNormalizedRect(rect, Int(viewSize.width), Int(viewSize.height))
            return CGRect(x: r.origin.x, y: viewSize.height - r.origin.y - r.height, width: r.width, height: r.height)
        }

        // aspectFill: 화면을 꽉 채우도록 스케일, 넘치는 부분 크롭
        let scale = max(viewSize.width / cameraImageSize.width,
                        viewSize.height / cameraImageSize.height)
        let displayedW = cameraImageSize.width * scale
        let displayedH = cameraImageSize.height * scale
        let offsetX = (displayedW - viewSize.width) / 2
        let offsetY = (displayedH - viewSize.height) / 2

        let screenX = rect.origin.x * displayedW - offsetX
        let screenY = (1 - rect.origin.y - rect.height) * displayedH - offsetY
        let screenW = rect.width * displayedW
        let screenH = rect.height * displayedH

        return CGRect(x: screenX, y: screenY, width: screenW, height: screenH)
    }

    // MARK: - 출석 처리


    private func performAttendance(employee: Employee, type: AttendanceType) {
        DebugLogger.shared.log(category: .faceAuth, message: "출석 처리 시작: \(employee.name) — \(type.rawValue)")
        recognitionManager.checkAttendance(for: employee, type: type)


        if let result = recognitionManager.lastAttendanceResult {
            if result.alreadyCheckedIn {
                resultToastMessage = "\(employee.name)님은 이미 출근 체크됨"
                resultToastSuccess = false
            } else {
                resultToastMessage = "\(employee.name)님 \(type.rawValue) 완료!"
                resultToastSuccess = true
            }
        }


        withAnimation(.spring(duration: 0.4)) {
            showResultToast = true
        }


        Task {
            try? await Task.sleep(for: .seconds(2.0))
            withAnimation {
                showResultToast = false
            }
            if autoDismissCamera && resultToastSuccess {
                try? await Task.sleep(for: .seconds(0.5))
                DebugLogger.shared.log(category: .faceAuth, message: "카메라 자동 닫기 실행")
                dismiss()
            }
        }
    }


    // MARK: - UI Components


    /// 결과 토스트
    private var resultToastView: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: resultToastSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(resultToastSuccess ? .green : .yellow)


                Text(resultToastMessage)
                    .font(.headline)
                    .foregroundStyle(.white)


                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(.ultraThinMaterial)
                    .shadow(color: .black.opacity(0.3), radius: 10)
            )
            .padding(.horizontal)
            .padding(.top, 60)


            Spacer()
        }
    }


    /// 상태 배지
    private var statusBadge: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(recognitionManager.isFaceDetected ? Color.green : Color.red)
                    .frame(width: 12, height: 12)


                if recognitionManager.isFaceDetected {
                    Text("얼굴 \(recognitionManager.faceObservations.count)명 감지됨")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                } else {
                    Text("얼굴을 찾는 중...")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }


            HStack(spacing: 6) {
                switch recognitionManager.modelStatus {
                case .loaded:
                    Image(systemName: "cpu.fill")
                        .foregroundStyle(.green)
                    Text("AuraFace 로드됨")
                        .foregroundStyle(.green)
                case .mockMode:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text("목업 모드 (모델 없음)")
                        .foregroundStyle(.yellow)
                case .notLoaded:
                    Image(systemName: "hourglass")
                        .foregroundStyle(.gray)
                    Text("모델 확인 중...")
                        .foregroundStyle(.gray)
                }
            }
            .font(.caption)
            .fontWeight(.medium)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }


    /// 닫기 버튼
    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark.circle.fill")
                .font(.title2)
                .foregroundStyle(.white)
                .shadow(radius: 4)
        }
    }


    /// 매칭된 사원 목록
    private var matchedEmployeesList: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "person.3.fill")
                    .foregroundStyle(.blue)
                Text("유사도 높은 사원")
                    .font(.headline)
                Spacer()
            }
            .padding()
            .background(Color(.systemBackground))


            Divider()


            ScrollView {
                VStack(spacing: 12) {
                    ForEach(recognitionManager.detectedMatches) { match in
                        EmployeeMatchCard(match: match) {
                            selectedEmployee = match.employee
                            showAttendanceConfirm = true
                        }
                    }
                }
                .padding()
            }
            .frame(maxHeight: 300)
        }
        .background(.ultraThinMaterial)
        .cornerRadius(20, corners: [.topLeft, .topRight])
    }
}


// MARK: - Employee Match Card


struct EmployeeMatchCard: View {
    let match: FaceMatch
    let onTap: () -> Void


    private var alreadyCheckedIn: Bool {
        AttendanceStore.shared.hasCheckedInToday(employeeId: match.employee.id)
    }


    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .fill(Color.blue.gradient)
                        .frame(width: 60, height: 60)


                    Text(match.employee.name.prefix(1))
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                }


                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(match.employee.name)
                            .font(.headline)
                            .foregroundStyle(.primary)


                        if alreadyCheckedIn {
                            Text("출근완료")
                                .font(.caption2)
                                .fontWeight(.semibold)
                                .foregroundStyle(.green)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(Color.green.opacity(0.12))
                                .cornerRadius(3)
                        }
                    }


                    Text(match.employee.department)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }


                Spacer()


                VStack(spacing: 4) {
                    Text("\(match.confidencePercent)%")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(confidenceColor)


                    Text("유사도")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
        }
        .buttonStyle(.plain)
    }


    private var confidenceColor: Color {
        switch match.confidence {
        case 0.7...:
            return .green
        case 0.5..<0.7:
            return .orange
        default:
            return .red
        }
    }
}


// MARK: - Custom Corner Radius


extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}


struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners


    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(
            roundedRect: rect,
            byRoundingCorners: corners,
            cornerRadii: CGSize(width: radius, height: radius)
        )
        return Path(path.cgPath)
    }
}


#Preview {
    FaceRecognitionView()
}



