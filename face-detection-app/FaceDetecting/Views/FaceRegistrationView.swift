import SwiftUI
import AVFoundation

struct FaceRegistrationView: View {
    @ObservedObject var viewModel: FaceRecognitionViewModel
    @StateObject private var apiService = APIService.shared
    @Environment(\.dismiss) var dismiss

    var preselectedEmployee: Employee? = nil

    @State private var selectedEmployee: Employee?
    @State private var phase: Phase = .picking

    enum Phase { case picking, capturing, done }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .picking:
                    employeePickerView
                case .capturing:
                    cameraView
                case .done:
                    completionView
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") {
                        viewModel.cancelRegistration()
                        dismiss()
                    }
                }
            }
        }
        .onAppear {
            viewModel.cameraManager.start()
            // Preselected employee: skip picker and start immediately
            if let emp = preselectedEmployee {
                selectedEmployee = emp
                startCapture()
            }
        }
        .onDisappear {
            if phase != .done {
                viewModel.cancelRegistration()
            }
        }
    }

    // MARK: - Start capture

    private func startCapture() {
        viewModel.startRegistration()
        withAnimation { phase = .capturing }
    }

    // MARK: - Phase: Employee Picker

    private var employeePickerView: some View {
        VStack(spacing: 0) {
            if apiService.isLoading {
                Spacer()
                ProgressView("読み込み中...")
                Spacer()
            } else {
                List(apiService.employees) { employee in
                    Button {
                        selectedEmployee = employee
                        startCapture()
                    } label: {
                        HStack(spacing: 14) {
                            ZStack {
                                Circle()
                                    .fill(LinearGradient(
                                        colors: [.blue, .indigo],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing))
                                    .frame(width: 44, height: 44)
                                Text(employee.initials)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.white)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                Text(employee.userName)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundColor(.primary)
                                Text(employee.department)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: "camera.fill")
                                .foregroundColor(.blue)
                                .font(.subheadline)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.insetGrouped)
            }
        }
        .navigationTitle("社員を選択")
        .task { await apiService.loadEmployees() }
    }

    // MARK: - Phase: Camera Capture

    private var cameraView: some View {
        GeometryReader { geo in
            ZStack {
                // Camera background
                if viewModel.cameraManager.isAuthorized {
                    CameraPreviewView(
                        session: viewModel.cameraManager.session,
                        rotationAngle: viewModel.rotationAngle
                    )
                    .ignoresSafeArea()
                    .onReceive(viewModel.cameraManager.$currentBuffer) { buf in
                        guard let buf = buf else { return }
                        viewModel.processFrame(buffer: buf)
                    }
                } else {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 12) {
                        Image(systemName: "camera.fill")
                            .font(.largeTitle)
                            .foregroundColor(.white)
                        Text("カメラへのアクセスを許可してください")
                            .foregroundColor(.white)
                    }
                }

                // Overlay
                captureOverlay(geo: geo)
            }
        }
        .ignoresSafeArea()
        .navigationTitle(selectedEmployee?.userName ?? "顔登録")
        .onChange(of: viewModel.registrationProgress) { _, progress in
            if progress >= 1.0 {
                withAnimation { phase = .done }
            }
        }
    }

    private func captureOverlay(geo: GeometryProxy) -> some View {
        let guideSize: CGFloat = min(geo.size.width * 0.72, 280)
        let progress = viewModel.registrationProgress
        let hasFace = !viewModel.detectedFaces.isEmpty

        return VStack(spacing: 0) {
            // Name + status
            VStack(spacing: 6) {
                if let emp = selectedEmployee {
                    Text(emp.userName)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                }
                Text(hasFace ? "顔を検出中..." : "カメラに顔を向けてください")
                    .font(.subheadline)
                    .foregroundColor(hasFace ? .green : .white.opacity(0.7))
                    .animation(.easeInOut, value: hasFace)
            }
            .padding(.top, geo.safeAreaInsets.top + 20)
            .padding(.horizontal, 20)

            Spacer()

            // Face guide circle
            ZStack {
                // Outer ring
                Circle()
                    .stroke(Color.white.opacity(0.15), lineWidth: 2)
                    .frame(width: guideSize + 20, height: guideSize + 20)

                // Detection ring
                Circle()
                    .stroke(hasFace ? Color.green : Color.white.opacity(0.4),
                            lineWidth: hasFace ? 3 : 1.5)
                    .frame(width: guideSize, height: guideSize)
                    .animation(.easeInOut(duration: 0.3), value: hasFace)

                // Progress arc
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        LinearGradient(
                            colors: [.green, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .frame(width: guideSize, height: guideSize)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.2), value: progress)

                // Face icon
                Image(systemName: hasFace ? "person.fill" : "person.and.background.dotted")
                    .font(.system(size: guideSize * 0.22))
                    .foregroundColor(hasFace ? .green.opacity(0.8) : .white.opacity(0.25))
                    .animation(.easeInOut, value: hasFace)
            }

            Spacer()

            // Progress bar + hint
            VStack(spacing: 14) {
                // Dots
                HStack(spacing: 10) {
                    ForEach(0..<15, id: \.self) { i in
                        Circle()
                            .fill(Float(i) < progress * 15 ? Color.green : Color.white.opacity(0.2))
                            .frame(width: 10, height: 10)
                            .animation(.spring(), value: progress)
                    }
                }

                Text("ゆっくり頭を動かしてください")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.7))

                // Quality badges
                HStack(spacing: 12) {
                    qualityBadge(
                        icon: "light.max",
                        label: viewModel.lightingStatus.rawValue,
                        ok: viewModel.lightingStatus == .good)
                    qualityBadge(
                        icon: "scope",
                        label: "顔を中央に",
                        ok: viewModel.isFaceCentered)
                }
            }
            .padding(.bottom, geo.safeAreaInsets.bottom + 24)
        }
    }

    private func qualityBadge(icon: String, label: String, ok: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok ? "checkmark.circle.fill" : icon)
                .font(.caption2)
                .foregroundColor(ok ? .green : .orange)
            Text(ok ? "OK" : label)
                .font(.caption2)
                .foregroundColor(ok ? .green : .orange)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.4))
        .clipShape(Capsule())
    }

    // MARK: - Phase: Done

    private var completionView: some View {
        VStack(spacing: 32) {
            Spacer()

            // Check icon
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 130, height: 130)
                Circle()
                    .stroke(Color.green.opacity(0.4), lineWidth: 2)
                    .frame(width: 130, height: 130)
                Image(systemName: "checkmark")
                    .font(.system(size: 56, weight: .bold))
                    .foregroundColor(.green)
            }

            VStack(spacing: 10) {
                Text("登録完了")
                    .font(.title.bold())
                if let name = selectedEmployee?.userName {
                    Text("\(name)さんの顔データを登録しました")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Spacer()

            Button {
                viewModel.finalizeRegistration(name: selectedEmployee?.userName ?? "")
                dismiss()
            } label: {
                Text("完了")
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.green)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 40)
        }
        .navigationTitle("")
    }
}

// MARK: - Quality Badge (standalone reuse)
struct QualityBadge: View {
    let icon: String
    let text: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: isActive ? icon : "checkmark.circle.fill")
                .font(.caption2)
                .foregroundColor(isActive ? .orange : .green)
            Text(isActive ? text : "OK")
                .font(.caption2)
                .foregroundColor(isActive ? .orange : .green)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.black.opacity(0.4))
        .clipShape(Capsule())
    }
}
