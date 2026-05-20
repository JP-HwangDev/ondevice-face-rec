//
//  AddEmployeeView.swift
//  FaceAuthApp
//
//  Created by yon on 2026/02/01.
//

import SwiftUI
import Vision

/// 사원 추가 화면
struct AddEmployeeView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = EmployeeStore.shared

    @State private var name = ""
    @State private var department = ""
    @State private var selectedDepartmentIndex = 0
    @State private var useCustomDepartment = false
    @State private var customDepartment = ""

    @State private var faceRegistered = false
    @State private var showCamera = false
    @State private var capturedVector: [Float]? = nil
    @State private var capturedVectors: [[Float]] = []

    @State private var showValidationAlert = false
    @State private var validationMessage = ""

    private let presetDepartments = ["개발팀", "디자인팀", "기획팀", "마케팅팀", "인사팀", "영업팀", "재무팀", "운영팀"]

    private var currentDepartment: String {
        useCustomDepartment ? customDepartment : presetDepartments[selectedDepartmentIndex]
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty &&
        !currentDepartment.trimmingCharacters(in: .whitespaces).isEmpty &&
        faceRegistered
    }

    var body: some View {
        NavigationStack {
            Form {
                // MARK: - 기본 정보
                Section {
                    HStack {
                        Text("이름")
                            .foregroundStyle(.secondary)
                        TextField("홍길동", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                } header: {
                    Text("기본 정보")
                }

                // MARK: - 부서
                Section {
                    Toggle("직접 입력", isOn: $useCustomDepartment)

                    if useCustomDepartment {
                        HStack {
                            Text("부서명")
                                .foregroundStyle(.secondary)
                            TextField("예: QA팀", text: $customDepartment)
                                .multilineTextAlignment(.trailing)
                        }
                    } else {
                        Picker("부서 선택", selection: $selectedDepartmentIndex) {
                            ForEach(presetDepartments.indices, id: \.self) { i in
                                Text(presetDepartments[i]).tag(i)
                            }
                        }
                    }
                } header: {
                    Text("부서")
                }

                // MARK: - 얼굴 등록
                Section {
                    if faceRegistered {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.title2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("얼굴 등록 완료")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(.primary)
                                let dim = capturedVectors.first?.count ?? 512
                                Text("\(capturedVectors.count)개 각도에서 \(dim)차원 벡터 수집됨")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("다시 등록") {
                                showCamera = true
                            }
                            .font(.caption)
                            .foregroundStyle(.blue)
                        }
                        .padding(.vertical, 4)
                    } else {
                        Button {
                            showCamera = true
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(Color.blue.opacity(0.12))
                                        .frame(width: 48, height: 48)
                                    Image(systemName: "camera.fill")
                                        .foregroundStyle(.blue)
                                        .font(.title3)
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("얼굴 등록하기")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text("카메라로 얼굴을 촬영해 등록합니다")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                } header: {
                    Text("얼굴 등록")
                } footer: {
                    if !faceRegistered {
                        Label("얼굴 등록은 필수입니다", systemImage: "info.circle")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
                }

                // MARK: - 미리보기
                if !name.isEmpty || faceRegistered {
                    Section {
                        HStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.gradient)
                                    .frame(width: 56, height: 56)
                                Text(name.isEmpty ? "?" : String(name.prefix(1)))
                                    .font(.title2)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.white)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(name.isEmpty ? "이름 미입력" : name)
                                    .font(.headline)
                                    .foregroundStyle(name.isEmpty ? .secondary : .primary)
                                Text(currentDepartment.isEmpty ? "부서 미선택" : currentDepartment)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("미리보기")
                    }
                }
            }
            .navigationTitle("사원 추가")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        saveEmployee()
                    }
                    .fontWeight(.semibold)
                    .disabled(!canSave)
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                FaceRegisterCameraView { vector, vectors in
                    capturedVector = vector
                    capturedVectors = vectors
                    faceRegistered = true
                }
            }
            .alert("입력 확인", isPresented: $showValidationAlert) {
                Button("확인", role: .cancel) { }
            } message: {
                Text(validationMessage)
            }
        }
    }

    private func saveEmployee() {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let trimmedDept = currentDepartment.trimmingCharacters(in: .whitespaces)

        guard !trimmedName.isEmpty else {
            validationMessage = "이름을 입력해주세요."
            showValidationAlert = true
            return
        }
        guard !trimmedDept.isEmpty else {
            validationMessage = "부서를 입력해주세요."
            showValidationAlert = true
            return
        }
        guard let vector = capturedVector else {
            validationMessage = "얼굴을 등록해주세요."
            showValidationAlert = true
            return
        }

        let employee = Employee(
            name: trimmedName,
            department: trimmedDept,
            faceVector: vector,
            faceVectors: capturedVectors
        )
        store.add(employee)
        dismiss()
    }
}

// MARK: - 연속 자동 캡처 얼굴 등록 카메라 화면

/// Face ID 스타일 연속 자동 캡처: 자연스럽게 머리를 돌리면 각도 변화 감지 시 자동 촬영
struct FaceRegisterCameraView: View {
    let onCapture: ([Float], [[Float]]) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var faceObservations: [VNFaceObservation] = []
    @State private var currentPixelBuffer: CVPixelBuffer?
    @State private var capturedVectors: [[Float]] = []
    @State private var capturedAngles: [(yaw: CGFloat, pitch: CGFloat)] = []
    @State private var currentYaw: CGFloat = 0
    @State private var currentPitch: CGFloat = 0
    @State private var isCompleted = false
    @State private var isFaceDetected = false
    @State private var lastCaptureTime: Date = .distantPast

    @State private var embeddingExtractor = FaceEmbeddingExtractor()

    /// 목표 캡처 수
    private let targetCaptures = 15
    /// 기존 캡처와 최소 각도 차이
    private let minAngleDiff: CGFloat = 0.07
    /// 캡처 간 최소 간격 (초)
    private let minCaptureInterval: TimeInterval = 0.25

    private var progress: Double {
        Double(capturedVectors.count) / Double(targetCaptures)
    }

    var body: some View {
        ZStack {
            CameraView(onFaceDetected: { observations, pixelBuffer in
                guard !isCompleted else { return }
                faceObservations = observations
                currentPixelBuffer = pixelBuffer
                isFaceDetected = !observations.isEmpty
                processFrame(from: observations)
            })
            .ignoresSafeArea()

            Color.black.opacity(0.3)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                headerBar
                    .padding(.top, 8)

                Spacer()

                faceGuideView

                Spacer()

                instructionView
                    .padding(.bottom, 40)
            }

            if isCompleted {
                completionOverlay
            }
        }
    }

    // MARK: - 상단 바

    private var headerBar: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("얼굴 등록")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text("\(capturedVectors.count)/\(targetCaptures)장 촬영")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .cornerRadius(12)

            Spacer()

            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal)
    }

    // MARK: - 얼굴 가이드 (프로그레스 링)

    private var faceGuideView: some View {
        ZStack {
            // 배경 링
            Circle()
                .stroke(Color.white.opacity(0.2), lineWidth: 6)
                .frame(width: 260, height: 260)

            // 진행 링
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .frame(width: 260, height: 260)
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.3), value: capturedVectors.count)

            // 중앙 아이콘 + 안내
            VStack(spacing: 12) {
                Image(systemName: isFaceDetected ? "face.smiling" : "face.dashed")
                    .font(.system(size: 48))
                    .foregroundStyle(isFaceDetected ? (capturedVectors.isEmpty ? .white : .green) : .gray)

                if isFaceDetected {
                    Text(guideText)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(capturedVectors.count > 0 ? .green : .white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial)
                        .cornerRadius(8)
                }
            }
        }
    }

    /// 현재 커버리지 상태에 따라 방향 안내
    private var guideText: String {
        if capturedVectors.isEmpty {
            return "정면을 바라봐 주세요"
        }
        if let suggestion = suggestedDirection {
            return suggestion
        }
        return "좋아요! 계속 움직여주세요"
    }

    /// 아직 커버되지 않은 방향 제안
    private var suggestedDirection: String? {
        let hasCenter = capturedAngles.contains { abs($0.yaw) < 0.1 && abs($0.pitch) < 0.1 }
        let hasLeft = capturedAngles.contains { $0.yaw > 0.2 }
        let hasRight = capturedAngles.contains { $0.yaw < -0.2 }
        let hasUp = capturedAngles.contains { $0.pitch < -0.1 }
        let hasDown = capturedAngles.contains { $0.pitch > 0.1 }

        if !hasCenter { return "정면을 바라봐 주세요" }
        if !hasLeft { return "왼쪽으로 천천히 돌려주세요" }
        if !hasRight { return "오른쪽으로 천천히 돌려주세요" }
        if !hasUp { return "위를 살짝 바라봐 주세요" }
        if !hasDown { return "아래를 살짝 바라봐 주세요" }
        return nil
    }

    // MARK: - 하단 커버리지 표시

    private var instructionView: some View {
        VStack(spacing: 12) {
            if !isFaceDetected {
                Text("카메라에 얼굴이 보이도록 해주세요")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            } else {
                HStack(spacing: 16) {
                    coverageDot(label: "←", covered: capturedAngles.contains { $0.yaw > 0.2 })
                    coverageDot(label: "↑", covered: capturedAngles.contains { $0.pitch < -0.1 })
                    coverageDot(label: "●", covered: capturedAngles.contains { abs($0.yaw) < 0.1 && abs($0.pitch) < 0.1 })
                    coverageDot(label: "↓", covered: capturedAngles.contains { $0.pitch > 0.1 })
                    coverageDot(label: "→", covered: capturedAngles.contains { $0.yaw < -0.2 })
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
            }
        }
    }

    private func coverageDot(label: String, covered: Bool) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(covered ? .green : .white.opacity(0.5))
            Circle()
                .fill(covered ? Color.green : Color.white.opacity(0.3))
                .frame(width: 8, height: 8)
        }
    }

    // MARK: - 완료 오버레이

    private var completionOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.2))
                        .frame(width: 100, height: 100)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(.green)
                }

                Text("얼굴 등록 완료!")
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)

                let dim = capturedVectors.first?.count ?? 512
                Text("\(capturedVectors.count)장에서 \(dim)차원 벡터를 수집했습니다")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.7))

                if embeddingExtractor.isModelLoaded {
                    Label("Core ML 모델 사용", systemImage: "cpu.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("목업 모드 (모델 없음)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            .padding(40)
            .background(.ultraThinMaterial)
            .cornerRadius(24)
        }
        .transition(.opacity)
    }

    // MARK: - 자동 캡처 로직

    private func processFrame(from observations: [VNFaceObservation]) {
        guard let face = observations.first else { return }

        currentYaw = face.yaw?.doubleValue ?? 0
        currentPitch = face.pitch?.doubleValue ?? 0

        // 캡처 간격 체크
        let now = Date()
        guard now.timeIntervalSince(lastCaptureTime) >= minCaptureInterval else { return }

        // 각도 다양성 체크
        guard isAngleDiverse(yaw: currentYaw, pitch: currentPitch) else { return }

        lastCaptureTime = now
        Task {
            await captureOneShot()
        }
    }

    /// 기존 캡처 각도들과 충분히 다른지 확인
    private func isAngleDiverse(yaw: CGFloat, pitch: CGFloat) -> Bool {
        if capturedAngles.isEmpty { return true }
        for existing in capturedAngles {
            if abs(yaw - existing.yaw) < minAngleDiff && abs(pitch - existing.pitch) < minAngleDiff {
                return false
            }
        }
        return true
    }

    private func captureOneShot() async {
        var vector: [Float]

        if embeddingExtractor.isModelLoaded,
           let pixelBuffer = currentPixelBuffer,
           let face = faceObservations.first,
           let embedding = await embeddingExtractor.extractEmbedding(from: pixelBuffer, boundingBox: face.boundingBox) {
            vector = embedding
        } else {
            let dim = embeddingExtractor.embeddingDimension
            vector = (0..<dim).map { _ in Float.random(in: -1...1) }
        }

        capturedVectors.append(vector)
        capturedAngles.append((yaw: currentYaw, pitch: currentPitch))

        DebugLogger.shared.log(category: .faceAuth,
            message: "자동 캡처 \(capturedVectors.count)/\(targetCaptures)",
            details: "yaw=\(String(format: "%.2f", currentYaw)) pitch=\(String(format: "%.2f", currentPitch))")

        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.impactOccurred()

        if capturedVectors.count >= targetCaptures {
            completeRegistration()
        }
    }

    private func completeRegistration() {
        isCompleted = true
        let avgVector = Employee.averageVector(from: capturedVectors)
        onCapture(avgVector, capturedVectors)

        DebugLogger.shared.log(category: .faceAuth,
            message: "얼굴 등록 완료: \(capturedVectors.count)장 수집",
            details: "차원: \(avgVector.count), 모델: \(embeddingExtractor.isModelLoaded ? "Core ML" : "목업")")

        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)

        Task {
            try? await Task.sleep(for: .seconds(1.5))
            dismiss()
        }
    }
}

#Preview {
    AddEmployeeView()
}
