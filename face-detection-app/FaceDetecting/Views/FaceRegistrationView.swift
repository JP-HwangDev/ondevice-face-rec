import SwiftUI
import AVFoundation

struct FaceRegistrationView: View {
    @ObservedObject var viewModel: FaceRecognitionViewModel
    @StateObject private var apiService = APIService.shared
    @Environment(\.dismiss) var dismiss

    var preselectedEmployee: Employee? = nil
    var mode: RegistrationMode = .employee

    @State private var selectedEmployee: Employee?
    @State private var phase: Phase = .picking
    @State private var visitorCompany = ""
    @State private var visitorName = ""
    @State private var visitorPurpose = ""
    @State private var isSubmittingVisitor = false
    @State private var visitorError: String?

    enum Phase { case picking, capturing, done }
    enum RegistrationMode { case employee, visitor }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .picking:
                    if mode == .visitor {
                        visitorFormView
                    } else {
                        employeePickerView
                    }
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

    private func startVisitorCapture() {
        visitorError = nil
        guard !visitorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            visitorError = "名前を入力してください"
            return
        }
        startCapture()
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

    private var visitorFormView: some View {
        Form {
            Section("訪問者情報") {
                TextField("会社名", text: $visitorCompany)
                    .textContentType(.organizationName)
                TextField("名前", text: $visitorName)
                    .textContentType(.name)
                TextField("訪問目的", text: $visitorPurpose)
            }

            if let visitorError {
                Section {
                    Text(visitorError)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }

            Section {
                Button {
                    startVisitorCapture()
                } label: {
                    Label("顔撮影へ進む", systemImage: "camera.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("訪問者登録")
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

                // Mask warning — takes priority over the normal capture guidance
                if viewModel.isMaskDetected {
                    maskWarningBanner(geo: geo)
                        .zIndex(10)
                }
            }
        }
        .ignoresSafeArea()
        .navigationTitle(mode == .visitor ? (visitorName.isEmpty ? "訪問者登録" : visitorName) : (selectedEmployee?.userName ?? "顔登録"))
        .onChange(of: viewModel.registrationProgress) { _, progress in
            if progress >= 1.0 {
                withAnimation { phase = .done }
                if mode == .visitor {
                    finalizeVisitor()
                } else {
                    viewModel.finalizeRegistration(name: selectedEmployee?.userName ?? "")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        dismiss()
                    }
                }
            }
        }
    }

    private func finalizeVisitor() {
        let name = visitorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let company = visitorCompany.trimmingCharacters(in: .whitespacesAndNewlines)
        let purpose = visitorPurpose.trimmingCharacters(in: .whitespacesAndNewlines)
        let photo = viewModel.currentFrameJPEGBase64()

        isSubmittingVisitor = true
        Task {
            do {
                try await apiService.registerVisitor(
                    company: company,
                    name: name,
                    purpose: purpose,
                    photoBase64: photo
                )
                await apiService.loadVisitors()
            } catch {
                print("[VisitorRegistration] API error: \(error)")
            }

            await MainActor.run {
                viewModel.finalizeVisitorRegistration(name: name, company: company, purpose: purpose)
                isSubmittingVisitor = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    dismiss()
                }
            }
        }
    }

    private func captureOverlay(geo: GeometryProxy) -> some View {
        let guideSize: CGFloat = min(geo.size.width * 0.72, 280)
        let progress = viewModel.registrationProgress
        let hasFace = !viewModel.detectedFaces.isEmpty
        let sampleCount = Int(progress * 30)

        return VStack(spacing: 0) {
            VStack(spacing: 6) {
                if mode == .visitor {
                    Text(visitorName)
                        .font(.title3.bold())
                        .foregroundColor(.white)
                } else if let emp = selectedEmployee {
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
                // Outer decorative ring
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 1.5)
                    .frame(width: guideSize + 24, height: guideSize + 24)

                // Progress track (background)
                Circle()
                    .stroke(Color.white.opacity(0.12), lineWidth: 9)
                    .frame(width: guideSize, height: guideSize)

                // Detection ring
                Circle()
                    .stroke(viewModel.isMaskDetected ? Color.red.opacity(0.6) : (hasFace ? Color.green.opacity(0.5) : Color.white.opacity(0.3)),
                            lineWidth: hasFace ? 2.5 : 1.5)
                    .frame(width: guideSize, height: guideSize)
                    .animation(.easeInOut(duration: 0.3), value: hasFace)
                    .animation(.easeInOut(duration: 0.3), value: viewModel.isMaskDetected)

                // Progress arc
                Circle()
                    .trim(from: 0, to: CGFloat(progress))
                    .stroke(
                        LinearGradient(
                            colors: [.green, .cyan],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 9, lineCap: .round))
                    .frame(width: guideSize, height: guideSize)
                    .rotationEffect(.degrees(-90))
                    .shadow(color: Color.green.opacity(progress > 0.05 ? 0.6 : 0), radius: 8)
                    .animation(.easeOut(duration: 0.2), value: progress)

                // Center: percentage + count, or icon when not started
                VStack(spacing: 3) {
                    if progress > 0 {
                        Text("\(Int(progress * 100))%")
                            .font(.system(size: guideSize * 0.17, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.5), radius: 2)
                        Text("\(sampleCount) / 30")
                            .font(.system(size: guideSize * 0.075, weight: .medium))
                            .foregroundColor(.white.opacity(0.55))
                    } else {
                        Image(systemName: hasFace ? "person.fill" : "person.and.background.dotted")
                            .font(.system(size: guideSize * 0.22))
                            .foregroundColor(hasFace ? .green.opacity(0.8) : .white.opacity(0.2))
                            .animation(.easeInOut, value: hasFace)
                    }
                }
            }

            Spacer()

            // Bottom progress panel
            VStack(spacing: 12) {
                // Face detection status
                HStack(spacing: 6) {
                    Circle()
                        .fill(viewModel.isMaskDetected ? Color.red : (hasFace ? Color.green : Color.orange))
                        .frame(width: 7, height: 7)
                    Text(viewModel.isMaskDetected ? "マスクを外してください" : (hasFace ? "顔を検出中..." : "カメラに顔を向けてください"))
                        .font(.caption)
                        .foregroundColor(viewModel.isMaskDetected ? .red : (hasFace ? .green : .white.opacity(0.7)))
                        .animation(.easeInOut, value: hasFace)
                        .animation(.easeInOut, value: viewModel.isMaskDetected)
                }

                // Segment dots
                HStack(spacing: 7) {
                    ForEach(0..<15, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Float(i) < progress * 15 ? Color.green : Color.white.opacity(0.18))
                            .frame(width: 14, height: 7)
                            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: progress)
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
            .padding(.vertical, 18)
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity)
            .background(Color.black.opacity(0.6))
            .cornerRadius(18)
            .overlay(
                RoundedRectangle(cornerRadius: 18)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .padding(.horizontal, 16)
            .padding(.bottom, geo.safeAreaInsets.bottom + 16)
        }
    }

    private func maskWarningBanner(geo: GeometryProxy) -> some View {
        VStack {
            HStack(spacing: 10) {
                Image(systemName: "facemask.fill")
                    .foregroundStyle(LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                Text("マスクを外してください")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color.orange.opacity(0.5), lineWidth: 1))
            .padding(.top, geo.safeAreaInsets.top + 8)

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: viewModel.isMaskDetected)
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
                let displayName = mode == .visitor ? visitorName : selectedEmployee?.userName
                if let name = displayName, !name.isEmpty {
                    Text("\(name)さんの顔データを登録しました")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                if isSubmittingVisitor {
                    ProgressView("サーバーへ登録中...")
                        .font(.caption)
                }
            }

            Spacer()

            Button {
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
