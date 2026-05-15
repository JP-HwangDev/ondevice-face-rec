import SwiftUI
import AVFoundation

struct FaceRegistrationView: View {
    @ObservedObject var viewModel: FaceRecognitionViewModel
    @StateObject private var apiService = APIService.shared
    @Environment(\.dismiss) var dismiss

    @State private var selectedEmployee: Employee?
    @State private var showingEmployeeSelection = true
    @State private var registrationComplete = false
    @State private var currentDirection: FaceDirection = .center
    @State private var completedDirections: Set<FaceDirection> = []
    @State private var pulseAnimation = false
    @State private var manualNameInput = ""
    @State private var showManualInput = false

    enum FaceDirection: String, CaseIterable {
        case center = "正面"
        case left = "左"
        case right = "右"
        case up = "上"
        case down = "下"
        case upLeft = "左上"
        case upRight = "右上"
        case downLeft = "左下"

        var angle: Double {
            switch self {
            case .center: return 0
            case .right: return 0
            case .upRight: return 45
            case .up: return 90
            case .upLeft: return 135
            case .left: return 180
            case .downLeft: return 225
            case .down: return 270
            }
        }

        var instruction: String {
            switch self {
            case .center: return "正面を向いてください"
            case .left: return "ゆっくり左を向いてください"
            case .right: return "ゆっくり右を向いてください"
            case .up: return "ゆっくり上を向いてください"
            case .down: return "ゆっくり下を向いてください"
            case .upLeft: return "左上を向いてください"
            case .upRight: return "右上を向いてください"
            case .downLeft: return "左下を向いてください"
            }
        }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Only show black background when not in camera mode
                if showingEmployeeSelection || registrationComplete {
                    Color.black.ignoresSafeArea()
                }

                if showingEmployeeSelection {
                    employeeSelectionView
                } else if registrationComplete {
                    registrationCompleteView
                } else {
                    GeometryReader { geometry in
                        faceRegistrationView(geometry: geometry)
                    }
                    .ignoresSafeArea()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("キャンセル") {
                        viewModel.cancelRegistration()
                        dismiss()
                    }
                    .foregroundColor(.white)
                }
            }
            .task {
                await apiService.loadEmployees()
            }
            .onAppear {
                // Ensure camera session is running
                viewModel.cameraManager.start()
            }
        }
    }

    // MARK: - Employee Selection View

    private var employeeSelectionView: some View {
        VStack(spacing: 25) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.3), .purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 100, height: 100)

                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 45))
                        .foregroundColor(.blue)
                }

                Text("顔登録")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)

                Text("登録する社員を選択してください")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 40)

            // Manual Input Toggle
            Button {
                withAnimation { showManualInput.toggle() }
            } label: {
                HStack {
                    Image(systemName: showManualInput ? "list.bullet" : "keyboard")
                    Text(showManualInput ? "リストから選択" : "手動で入力")
                }
                .font(.subheadline)
                .foregroundColor(.blue)
            }

            if showManualInput {
                // Manual Name Input
                VStack(spacing: 15) {
                    TextField("お名前を入力", text: $manualNameInput)
                        .textFieldStyle(.plain)
                        .padding()
                        .background(Color.white.opacity(0.1))
                        .cornerRadius(12)
                        .foregroundColor(.white)

                    if !manualNameInput.isEmpty {
                        Button {
                            withAnimation {
                                showingEmployeeSelection = false
                                viewModel.startRegistration()
                            }
                        } label: {
                            Text("この名前で登録開始")
                                .font(.headline)
                                .foregroundColor(.white)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Color.blue)
                                .cornerRadius(12)
                        }
                    }
                }
                .padding(.horizontal, 30)
            } else {
                // Employee List
                if apiService.isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(1.5)
                        .padding(.top, 50)
                } else if let error = apiService.errorMessage {
                    VStack(spacing: 15) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(error)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)

                        Button("手動入力に切り替え") {
                            withAnimation { showManualInput = true }
                        }
                        .foregroundColor(.blue)
                    }
                    .padding()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            // Show registered users first for re-registration
                            if !viewModel.store.users.isEmpty {
                                Section {
                                    ForEach(viewModel.store.users) { user in
                                        RegisteredUserCard(
                                            name: user.name,
                                            dataCount: user.faceSignatures.count,
                                            isSelected: manualNameInput == user.name
                                        ) {
                                            withAnimation(.spring()) {
                                                manualNameInput = user.name
                                                selectedEmployee = nil
                                            }
                                        }
                                    }
                                } header: {
                                    HStack {
                                        Text("登録済みユーザー（追加学習）")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 5)
                                }
                            }

                            // API Employees
                            if !apiService.employees.isEmpty {
                                Section {
                                    ForEach(apiService.employees) { employee in
                                        EmployeeSelectionCard(
                                            employee: employee,
                                            isSelected: selectedEmployee?.userNo == employee.userNo
                                        ) {
                                            withAnimation(.spring()) {
                                                selectedEmployee = employee
                                                manualNameInput = ""
                                            }
                                        }
                                    }
                                } header: {
                                    HStack {
                                        Text("社員リスト")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 5)
                                    .padding(.top, 10)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }

            Spacer()

            // Start Button
            if selectedEmployee != nil || !manualNameInput.isEmpty {
                Button {
                    withAnimation {
                        showingEmployeeSelection = false
                        viewModel.startRegistration()
                    }
                } label: {
                    HStack {
                        Text("登録を開始")
                            .font(.headline)
                        Image(systemName: "arrow.right")
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                    .background(
                        LinearGradient(colors: [Color(hex: "1A237E"), Color(hex: "0D47A1")], startPoint: .leading, endPoint: .trailing)
                    )
                    .cornerRadius(20)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(Color.white.opacity(0.2), lineWidth: 1)
                    )
                }
                .padding(.horizontal, 30)
                .padding(.bottom, 30)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .background(
            ZStack {
                Color(hex: "050A18").ignoresSafeArea()
                Circle()
                    .fill(Color.blue.opacity(0.15))
                    .frame(width: 400)
                    .blur(radius: 80)
                    .offset(x: -150, y: -200)
                Circle()
                    .fill(Color.purple.opacity(0.1))
                    .frame(width: 300)
                    .blur(radius: 70)
                    .offset(x: 100, y: 300)
            }
        )
    }

    // MARK: - Face Registration View

    // MARK: - Face Registration View
    private func faceRegistrationView(geometry: GeometryProxy) -> some View {
        let guideSize = min(geometry.size.width * 0.8, 320.0)
        let indicatorRadius = guideSize * 0.5
        
        return ZStack {
            // Camera Preview
            if viewModel.cameraManager.isAuthorized {
                CameraPreviewView(session: viewModel.cameraManager.session, rotationAngle: viewModel.rotationAngle)
                    .ignoresSafeArea()
                    .onReceive(viewModel.cameraManager.$currentBuffer) { buffer in
                        if let buffer = buffer {
                            viewModel.processFrame(buffer: buffer)
                        }
                    }
            }

                let isLandscape = geometry.size.width > geometry.size.height
                
                if isLandscape {
                    HStack(spacing: 40) {
                        // Left side: State & Quality
                        VStack(spacing: 24) {
                            VStack(spacing: 8) {
                                Text(registrationName)
                                    .font(.title2.bold())
                                    .foregroundColor(.white)

                                Text(currentDirection.instruction)
                                    .font(.headline)
                                    .foregroundColor(.cyan)
                                    .animation(.easeInOut, value: currentDirection)
                            }
                            
                            HStack(spacing: 15) {
                                QualityBadge(icon: "lightbulb.fill", text: viewModel.lightingStatus.rawValue, isActive: viewModel.lightingStatus != .good)
                                QualityBadge(icon: "scope", text: "정중앙", isActive: !viewModel.isFaceCentered)
                            }
                            
                            Spacer()
                            
                            // Bottom indicators moved to side in landscape
                            // Progress dots
                            instructionFooter
                        }
                        .padding(.vertical, 40)
                        .padding(.leading, geometry.safeAreaInsets.leading + 20)
                        .frame(maxWidth: 300)

                        Spacer()

                        // Right side: Face Guide
                        ZStack {
                            guideCircle(guideSize: guideSize, indicatorRadius: indicatorRadius)
                        }
                        .padding(.trailing, geometry.safeAreaInsets.trailing + 20)
                    }
                } else {
                    VStack {
                        // Header
                        VStack(spacing: 8) {
                            Text(registrationName)
                                .font(.title2.bold())
                                .foregroundColor(.white)

                            Text(currentDirection.instruction)
                                .font(.headline)
                                .foregroundColor(.cyan)
                                .animation(.easeInOut, value: currentDirection)
                        }
                        .padding(.top, max(geometry.safeAreaInsets.top, 50) + 20)

                        Spacer()

                        // Face Guide Circle
                        guideCircle(guideSize: guideSize, indicatorRadius: indicatorRadius)

                        // Real-time Quality Alerts
                        HStack(spacing: 15) {
                            QualityBadge(icon: "lightbulb.fill", text: viewModel.lightingStatus.rawValue, isActive: viewModel.lightingStatus != .good)
                            QualityBadge(icon: "scope", text: "정중앙으로 오세요", isActive: !viewModel.isFaceCentered)
                        }
                        .padding(.top, 40)

                        Spacer()

                        // Bottom instruction with progress dots
                        instructionFooter
                            .padding(.bottom, geometry.safeAreaInsets.bottom + 20)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .onAppear {
                withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                    pulseAnimation = true
                }
            }
            .onChange(of: viewModel.registrationProgress) { _, newValue in
                updateDirectionProgress(progress: newValue)

                if newValue >= 1.0 {
                    // Registration complete
                    let impact = UINotificationFeedbackGenerator()
                    impact.notificationOccurred(.success)

                    withAnimation(.spring()) {
                        registrationComplete = true
                    }
                } else if Int(newValue * 8) > Int((newValue - 0.125) * 8) {
                    // Direction completed - haptic feedback
                    let impact = UIImpactFeedbackGenerator(style: .medium)
                    impact.impactOccurred()
                }
            }
        }

    private func guideCircle(guideSize: CGFloat, indicatorRadius: CGFloat) -> some View {
        ZStack {
            // Outer guide with 3D effect
            Circle()
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
                .frame(width: guideSize, height: guideSize)
            
            // 3D Guidance Head (Visual Placeholder via SF Symbol)
            VStack {
                ZStack {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: guideSize * 0.375, height: guideSize * 0.375)
                        .overlay(Circle().stroke(Color.white.opacity(0.2)))
                    
                    Image(systemName: "faceid")
                        .font(.system(size: guideSize * 0.1875))
                        .foregroundColor(.white.opacity(0.8))
                        // Simulate 3D rotation based on head position
                        .rotation3DEffect(.degrees(Double(viewModel.currentYaw * -60)), axis: (x: 0, y: 1, z: 0))
                        .rotation3DEffect(.degrees(Double(viewModel.currentPitch * -60)), axis: (x: 1, y: 0, z: 0))
                }
                
                Text("고개를 가이드 방향으로 돌려주세요")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white.opacity(0.6))
                    .padding(.top, 10)
            }

            // Direction indicators
            ForEach(FaceDirection.allCases.filter { $0 != .center }, id: \.self) { direction in
                DirectionIndicator(
                    direction: direction,
                    isCompleted: completedDirections.contains(direction),
                    isCurrent: currentDirection == direction,
                    radius: indicatorRadius
                )
            }

            // Progress arc
            Circle()
                .trim(from: 0, to: CGFloat(viewModel.registrationProgress))
                .stroke(
                    LinearGradient(
                        colors: [Color(hex: "00C853"), Color(hex: "64FFDA")],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 6, lineCap: .round)
                )
                .frame(width: guideSize * 0.875, height: guideSize * 0.875)
                .rotationEffect(.degrees(-90))
        }
    }

    private var instructionFooter: some View {
        VStack(spacing: 20) {
            // Progress dots
            HStack(spacing: 12) {
                ForEach(0..<8, id: \.self) { index in
                    Circle()
                        .fill(index < Int(viewModel.registrationProgress * 8) ? Color.green : Color.white.opacity(0.2))
                        .frame(width: 12, height: 12)
                        .scaleEffect(index < Int(viewModel.registrationProgress * 8) ? 1.0 : 0.8)
                        .animation(.spring(), value: viewModel.registrationProgress)
                }
            }

            Text("ゆっくり頭を動かしてください")
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.8))
                .padding(.horizontal, 25)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
        }
    }

    private var registrationName: String {
        if let employee = selectedEmployee {
            return employee.userName
        }
        return manualNameInput.isEmpty ? "新規ユーザー" : manualNameInput
    }

    // MARK: - Registration Complete View

    private var registrationCompleteView: some View {
        VStack(spacing: 30) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.green.opacity(0.3), .cyan.opacity(0.2)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 200, height: 200)

                Circle()
                    .stroke(
                        LinearGradient(colors: [.green, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 4
                    )
                    .frame(width: 180, height: 180)

                Image(systemName: "checkmark")
                    .font(.system(size: 80, weight: .bold))
                    .foregroundColor(.green)
            }
            .symbolEffect(.bounce, value: registrationComplete)

            VStack(spacing: 12) {
                Text("登録完了")
                    .font(.largeTitle.bold())
                    .foregroundColor(.white)

                Text("\(registrationName)さんの\n顔データを登録しました")
                    .font(.body)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)

                Text("15個の高品質顔データを保存")
                    .font(.caption)
                    .foregroundColor(.cyan)
                    .padding(.top, 5)
            }

            Spacer()

            Button {
                viewModel.finalizeRegistration(name: registrationName)
                dismiss()
            } label: {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                    Text("完了")
                }
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .background(
                    LinearGradient(colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing)
                )
                .cornerRadius(16)
            }
            .padding(.horizontal, 30)
            .padding(.bottom, 50)
        }
    }

    // MARK: - Helper Methods

    private func updateDirectionProgress(progress: Float) {
        let directions: [FaceDirection] = [.center, .right, .upRight, .up, .upLeft, .left, .downLeft, .down]
        let directionIndex = min(Int(progress * Float(directions.count)), directions.count - 1)

        if directionIndex > 0 {
            let completedIndex = directionIndex - 1
            if completedIndex < directions.count {
                completedDirections.insert(directions[completedIndex])
            }
        }

        if directionIndex < directions.count {
            currentDirection = directions[directionIndex]
        }
    }
}

// MARK: - Supporting Views

struct EmployeeSelectionCard: View {
    let employee: Employee
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.4), .purple.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)

                    Text(employee.initials)
                        .font(.headline)
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(employee.userName)
                        .font(.headline)
                        .foregroundColor(.white)

                    Text(employee.teamName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.green)
                } else {
                    Circle()
                        .stroke(Color.white.opacity(0.3), lineWidth: 2)
                        .frame(width: 24, height: 24)
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color.white.opacity(isSelected ? 0.15 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(isSelected ? Color.blue : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct RegisteredUserCard: View {
    let name: String
    let dataCount: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [.green.opacity(0.4), .cyan.opacity(0.2)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 50, height: 50)

                    Text(String(name.prefix(1)))
                        .font(.headline)
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(name)
                        .font(.headline)
                        .foregroundColor(.white)

                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        Text("\(dataCount)個のデータ")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    Text("追加学習")
                        .font(.caption2)
                        .foregroundColor(.cyan)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title3)
                            .foregroundColor(.green)
                    }
                }
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 15)
                    .fill(Color.white.opacity(isSelected ? 0.15 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 15)
                            .stroke(isSelected ? Color.green : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(PlainButtonStyle())
    }
}

struct DirectionIndicator: View {
    let direction: FaceRegistrationView.FaceDirection
    let isCompleted: Bool
    let isCurrent: Bool
    let radius: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(isCompleted ? Color.green : (isCurrent ? Color.cyan : Color.white.opacity(0.1)))
                .frame(width: 32, height: 32)
                .overlay(Circle().stroke(isCurrent ? .white : .clear, lineWidth: 2))

            if isCompleted {
                Image(systemName: "checkmark")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white)
            } else {
                Text(direction.rawValue)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(isCurrent ? .white : .white.opacity(0.3))
            }
        }
        .shadow(color: isCompleted ? .green.opacity(0.5) : .clear, radius: 5)
        .offset(offsetForDirection)
        .animation(.spring(response: 0.3), value: isCompleted)
        .animation(.spring(response: 0.3), value: isCurrent)
    }

    private var offsetForDirection: CGSize {
        let angle = direction.angle * .pi / 180

        return CGSize(
            width: sin(angle) * radius,
            height: -cos(angle) * radius
        )
    }
}

struct QualityBadge: View {
    let icon: String
    let text: String
    let isActive: Bool
    
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(text)
        }
        .font(.caption.bold())
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isActive ? Color.red.opacity(0.8) : Color.white.opacity(0.1))
        .foregroundColor(.white)
        .cornerRadius(10)
        .opacity(isActive ? 1.0 : 0.3)
        .animation(.easeInOut, value: isActive)
    }
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default: (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(.sRGB, red: Double(r) / 255, green: Double(g) / 255, blue:  Double(b) / 255, opacity: Double(a) / 255)
    }
}
