import SwiftUI
import AVFoundation
import AudioToolbox
import UniformTypeIdentifiers
import Combine
import Charts

struct ContentView: View {
    @StateObject var viewModel = FaceRecognitionViewModel()
    @StateObject var apiService = APIService.shared

    @State private var showingSettings = false
    @State private var showingFaceRegistration = false
    @State private var showingAttendanceConfirm = false
    @State private var showingSuccessOverlay = false
    @State private var showingPasswordPrompt = false
    @State private var showingStats = false
    @State private var showingVisitorRegistration = false
    @State private var visitorName = ""
    @State private var visitPurpose = ""

    @State private var selectedCandidate: FaceRecognitionViewModel.Candidate?
    @State private var attendanceMessage = ""
    @State private var attendanceType: AttendanceType = .checkIn
    @State private var passwordInput = ""
    @State private var passwordError = false

    @State private var isScanning = false
    @State private var currentTime = Date()
    @State private var showingResetConfirm = false
    @State private var lastCheckInTime: Date? = nil
    @State private var lastCheckOutTime: Date? = nil

    private let settingsPassword = "20170201"
    @AppStorage("requireSmileForAttendance") private var requireSmile = true

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            
            ZStack {
                // Camera + Background
                backgroundView
                
                // UI Overlay
                VStack(spacing: 0) {
                    headerView(safeAreaTop: geometry.safeAreaInsets.top)
                        .padding(.horizontal, 20)
                    
                    if isLandscape {
                        HStack(alignment: .bottom, spacing: 20) {
                            mainContentArea
                            
                            Spacer()
                            
                            if let face = viewModel.detectedFaces.first(where: { $0.rawSimilarity > 0.72 }) {
                                recognizedUserPanel(face: face, geometry: geometry)
                                    .padding(.trailing, geometry.safeAreaInsets.trailing + 20)
                            } else {
                                bottomSection(geometry: geometry)
                                    .frame(width: 300)
                                    .padding(.trailing, geometry.safeAreaInsets.trailing + 20)
                            }
                        }
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 20)
                    } else {
                        Spacer()
                        
                        mainContentArea
                        
                        Spacer()
                        
                        bottomSection(geometry: geometry)
                            .padding(.horizontal, 16)
                            .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? geometry.safeAreaInsets.bottom : 20)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                
                // Success Overlay
                if showingSuccessOverlay {
                    successOverlayView
                        .zIndex(100)
                }
                
                // Visitor Registration Overlay
                if showingVisitorRegistration {
                    visitorRegistrationOverlay(geometry: geometry)
                        .zIndex(200)
                }
            }
        }
        .ignoresSafeArea()
        .onReceive(timer) { _ in currentTime = Date() }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.8).repeatForever()) { isScanning = true }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(viewModel: viewModel)
        }
        .sheet(isPresented: $showingStats) {
            StatsView(viewModel: viewModel)
        }
        .onChange(of: showingSettings) { _, isPresented in
            if !isPresented {
                // Return from settings
                viewModel.cameraManager.start()
                viewModel.refreshID = UUID() // Refresh view
            }
        }
        .alert("パスワード入力", isPresented: $showingPasswordPrompt) {
            SecureField("パスワード", text: $passwordInput)
            Button("確認") {
                if passwordInput == settingsPassword {
                    passwordInput = ""
                    passwordError = false
                    showingSettings = true
                } else {
                    passwordError = true
                    passwordInput = ""
                }
            }
            Button("キャンセル", role: .cancel) {
                passwordInput = ""
                passwordError = false
            }
        } message: {
            if passwordError {
                Text("パスワードが間違っています")
            } else {
                Text("設定を開くにはパスワードを入力してください")
            }
        }
        .fullScreenCover(isPresented: $showingFaceRegistration) {
            FaceRegistrationView(viewModel: viewModel)
        }
        .onChange(of: showingFaceRegistration) { _, isPresented in
            if !isPresented {
                // Return from registration
                viewModel.cameraManager.start()
                viewModel.refreshID = UUID() // Refresh view
            }
        }
        .alert("出退勤確認", isPresented: $showingAttendanceConfirm) {
            Button("はい") { processAttendance() }
            Button("いいえ", role: .cancel) { selectedCandidate = nil }
        } message: {
            if let candidate = selectedCandidate {
                let status = viewModel.store.getTodayStatus(for: candidate.name)
                let action = status == .notCheckedIn ? "出勤" : "退勤"
                Text("\(candidate.name)さん、\(action)しますか？")
            }
        }
        .task {
            await apiService.loadEmployees()
        }
        .onChange(of: viewModel.shouldAutoAttendance) { _, shouldShow in
            if shouldShow {
                // Auto-select the recognized user
                if let face = viewModel.detectedFaces.first,
                   let candidate = face.candidates.first {
                    // Skip auto-attendance for visitors
                    let isVisitor = viewModel.store.users.first(where: { $0.name == candidate.name })?.userType == .visitor
                    if isVisitor {
                        viewModel.resetAutoAttendance()
                        return
                    }
                    
                    let status = viewModel.store.getTodayStatus(for: candidate.name)
                    
                    // Block auto-attendance during cooldown periods
                    if status == .checkedIn, let t = lastCheckInTime, Date().timeIntervalSince(t) < 60 {
                        viewModel.resetAutoAttendance()
                        return
                    }
                    if status == .checkedOut, let t = lastCheckOutTime, Date().timeIntervalSince(t) < 60 {
                        viewModel.resetAutoAttendance()
                        return
                    }
                    if status == .checkedOut {
                        // Already done for the day — don't show alert
                        viewModel.resetAutoAttendance()
                        return
                    }
                    
                    selectedCandidate = candidate
                    showingAttendanceConfirm = true
                }
            }
        }
    }

    // MARK: - Components
    
    private var cameraLayer: some View {
        Group {
            if viewModel.cameraManager.isAuthorized && !showingFaceRegistration && !showingSettings {
                 CameraPreviewView(session: viewModel.cameraManager.session, rotationAngle: viewModel.rotationAngle, faces: viewModel.detectedFaces, isLivenessVerified: viewModel.isLivenessVerified)
                    .id(viewModel.refreshID) // Force view refresh
                    .ignoresSafeArea()
                    .onReceive(viewModel.cameraManager.$currentBuffer) { buffer in
                        if let buffer = buffer { viewModel.processFrame(buffer: buffer) }
                    }
                    .onAppear {
                        // Ensure session is running when view appears
                        viewModel.cameraManager.start()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.black.ignoresSafeArea()
                    .onReceive(viewModel.cameraManager.$currentBuffer) { buffer in
                        if let buffer = buffer { viewModel.processFrame(buffer: buffer) }
                    }
                if !viewModel.cameraManager.isAuthorized {
                    VStack {
                        Image(systemName: "camera.fill")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("카메라 접근 권한이 필요합니다")
                            .foregroundColor(.gray)
                    }
                }
            }
        }
    }

    private var backgroundView: some View {
        ZStack {
            Color(hex: "02050B").ignoresSafeArea()
            
            // Camera Background (Integrated)
            cameraLayer
                .opacity(0.8)
            
            // Subtle ambient glows
            Circle()
                .fill(Color(hex: "1A237E").opacity(0.3))
                .frame(width: 500)
                .blur(radius: 100)
                .offset(x: -200, y: -300)
            
            Circle()
                .fill(Color(hex: "006064").opacity(0.2))
                .frame(width: 400)
                .blur(radius: 80)
                .offset(x: 150, y: 300)
        }
    }

    private func headerView(safeAreaTop: CGFloat) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Smart Attendance")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                
                Text(dateString)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
            }
            
            Spacer()
            
            Text(timeString)
                .font(.system(size: 16, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
                .padding(.trailing, 8)
            
            HStack(spacing: 12) {
                Button {
                    showingStats = true
                } label: {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
                
                Button {
                    showingPasswordPrompt = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.8))
                        .frame(width: 40, height: 40)
                        .background(.ultraThinMaterial)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.top, max(safeAreaTop, 20))
        .padding(.bottom, 8)
    }

    private var mainContentArea: some View {
        VStack {
            if viewModel.isRegistering {
                registrationProgressView
            } else {
                Spacer()
                
                // Show Visitor Button if unknown face is prominent but not recognized
                if let face = viewModel.detectedFaces.first, face.name == "未認証" || face.name == "認証中..." {
                    Button {
                        showingVisitorRegistration = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.badge.plus.fill")
                                .font(.system(size: 18))
                            Text("방문자 등록하기")
                                .font(.system(size: 16, weight: .bold))
                        }
                        .foregroundColor(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(colors: [Color(hex: "3949AB"), Color(hex: "1E88E5")], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(30)
                        .shadow(color: .blue.opacity(0.3), radius: 10, y: 5)
                    }
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    // MARK: - Face Overlay Layer
    private var faceOverlayLayer: some View {
        Canvas { context, size in
            for face in viewModel.detectedFaces {
                let isRecognized = face.name != "未認証" && !face.name.isEmpty
                let statusColor = getStatusColor(for: face.attendanceStatus)
                let color: Color = isRecognized ? statusColor : .cyan

                // Draw landmarks
                for (_, points) in face.landmarks {
                    var path = Path()
                    let converted = points.map { convertPoint($0, to: size) }
                    if let first = converted.first {
                        path.move(to: first)
                        for i in 1..<converted.count { path.addLine(to: converted[i]) }
                    }
                    context.stroke(path, with: .color(color.opacity(0.6)), lineWidth: 1.5)
                }

                // Draw face box corners with glow for recognized faces
                let rect = convertRect(face.rect, to: size)
                if isRecognized {
                    // Glow effect
                    drawModernCorners(context: context, rect: rect.insetBy(dx: -2, dy: -2), color: color.opacity(0.3))
                }
                drawModernCorners(context: context, rect: rect, color: color)

                // Draw name label
                if !face.name.isEmpty {
                    drawNameLabel(context: context, face: face, rect: rect, size: size, color: color)
                }
                
                // Liveness Verified Badge
                if viewModel.isLivenessVerified {
                    drawLivenessBadge(context: context, rect: rect, color: color)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    private func drawLivenessBadge(context: GraphicsContext, rect: CGRect, color: Color) {
        let badgeRect = CGRect(x: rect.maxX - 20, y: rect.minY - 30, width: 24, height: 24)
        context.fill(Path(ellipseIn: badgeRect), with: .color(color))
        
        let resolvedIcon = context.resolve(
            Text(Image(systemName: "checkmark.shield.fill"))
                .font(.system(size: 14))
                .foregroundColor(.white)
        )
        context.draw(resolvedIcon, in: badgeRect.insetBy(dx: 4, dy: 4))
    }

    private func getStatusColor(for status: UserAttendanceStatus) -> Color {
        switch status {
        case .notCheckedIn: return .orange
        case .checkedIn: return .green
        case .checkedOut: return .blue
        }
    }

    private func drawModernCorners(context: GraphicsContext, rect: CGRect, color: Color) {
        let cornerLength: CGFloat = 25
        let lineWidth: CGFloat = 3

        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: rect.minX, y: rect.minY + cornerLength),
             CGPoint(x: rect.minX, y: rect.minY),
             CGPoint(x: rect.minX + cornerLength, y: rect.minY)),
            (CGPoint(x: rect.maxX - cornerLength, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.minY),
             CGPoint(x: rect.maxX, y: rect.minY + cornerLength)),
            (CGPoint(x: rect.minX, y: rect.maxY - cornerLength),
             CGPoint(x: rect.minX, y: rect.maxY),
             CGPoint(x: rect.minX + cornerLength, y: rect.maxY)),
            (CGPoint(x: rect.maxX - cornerLength, y: rect.maxY),
             CGPoint(x: rect.maxX, y: rect.maxY),
             CGPoint(x: rect.maxX, y: rect.maxY - cornerLength))
        ]

        for (start, corner, end) in corners {
            var path = Path()
            path.move(to: start)
            path.addLine(to: corner)
            path.addLine(to: end)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
        }
    }

    private func drawNameLabel(context: GraphicsContext, face: FaceRecognitionViewModel.RecognizedFace, rect: CGRect, size: CGSize, color: Color) {
        let text = face.name == "未認証" ? "UNKNOWN" : "\(face.name) \(face.score)%"

        let resolvedText = context.resolve(
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        )

        let textSize = resolvedText.measure(in: size)
        let padding: CGFloat = 10
        let backgroundRect = CGRect(
            x: rect.midX - (textSize.width + padding * 2) / 2,
            y: rect.minY - textSize.height - padding * 2 - 10,
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )

        // Draw background
        let bgPath = Path(roundedRect: backgroundRect, cornerRadius: 10)
        context.fill(bgPath, with: .color(color.opacity(0.85)))

        // Draw text
        context.draw(resolvedText, at: CGPoint(x: backgroundRect.midX, y: backgroundRect.midY))
    }

    private var timeString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: currentTime)
    }

    private var dateString: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年MM月dd日 (E)"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: currentTime)
    }

    // MARK: - Registration Progress View
    private var registrationProgressView: some View {
        VStack(spacing: 25) {
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: CGFloat(viewModel.registrationProgress))
                    .stroke(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                VStack(spacing: 5) {
                    Text("\(Int(viewModel.registrationProgress * 100))%")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text("収集中")
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.7))
                }
            }
            .frame(width: 150, height: 150)

            Text("ゆっくり顔を回してください")
                .font(.headline)
                .foregroundColor(.white)
                .padding(.horizontal, 25)
                .padding(.vertical, 12)
                .background(.ultraThinMaterial)
                .cornerRadius(20)
        }
        .transition(.scale.combined(with: .opacity))
    }

    // MARK: - Smile Progress View
    private var smileProgressView: some View {
        VStack(spacing: 8) {
            Text("😁 Smile to Check-in")
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.2))
                    Capsule()
                        .fill(LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * CGFloat(viewModel.smileConfidence))
                }
            }
            .frame(height: 8)
            .frame(width: 200)
        }
        .padding(15)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
        .shadow(radius: 10)
    }

    // MARK: - Bottom Section
    private func bottomSection(geometry: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            if let face = viewModel.detectedFaces.first(where: { !$0.candidates.isEmpty }) {
                recognizedUserPanel(face: face, geometry: geometry)
            } else {
                // No face: show nothing (clean)
                EmptyView()
            }
        }
    }

    // MARK: - Confidence Gauge
    private func confidenceGauge(similarity: Float) -> some View {
        HStack(spacing: 12) {
            // Circular gauge
            ZStack {
                Circle()
                    .stroke(Color.white.opacity(0.1), lineWidth: 4)
                    .frame(width: 36, height: 36)
                Circle()
                    .trim(from: 0, to: CGFloat(similarity))
                    .stroke(
                        gaugeGradient(for: similarity),
                        style: StrokeStyle(lineWidth: 4, lineCap: .round)
                    )
                    .frame(width: 36, height: 36)
                    .rotationEffect(.degrees(-90))
                
                Text("\(Int(similarity * 100))")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text("認識信頼度")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.5))
                
                // Bar gauge
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                        Capsule()
                            .fill(gaugeGradient(for: similarity))
                            .frame(width: geo.size.width * CGFloat(similarity))
                    }
                }
                .frame(height: 6)
                .frame(width: 120)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .cornerRadius(20)
    }

    private func gaugeGradient(for similarity: Float) -> LinearGradient {
        if similarity >= 0.8 {
            return LinearGradient(colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing)
        } else if similarity >= 0.65 {
            return LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing)
        } else {
            return LinearGradient(colors: [.red, .orange], startPoint: .leading, endPoint: .trailing)
        }
    }

    private func recognizedUserPanel(face: FaceRecognitionViewModel.RecognizedFace, geometry: GeometryProxy) -> some View {
        VStack(spacing: 12) {
            // Handle
            Capsule()
                .fill(Color.white.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.top, 10)

            // User info
            VStack(spacing: 8) {
                Text(face.name)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundColor(.white)
                
                let isVisitor = viewModel.store.users.first(where: { $0.name == face.name })?.userType == .visitor
                
                HStack(spacing: 8) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(face.score >= 85 ? Color.green : Color.yellow)
                            .frame(width: 8, height: 8)
                        Text("\(Int(face.score))%")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                    }
                    
                    Text("·")
                        .foregroundColor(.white.opacity(0.3))
                    
                    Text(isVisitor ? "訪問者" : "社員")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(isVisitor ? .orange : .cyan)
                }
                
                // Top 3 候補者
                if face.candidates.count > 1 {
                    VStack(spacing: 5) {
                        ForEach(Array(face.candidates.prefix(3).enumerated()), id: \.element.id) { idx, candidate in
                            HStack(spacing: 8) {
                                Text("\(idx + 1)")
                                    .font(.system(size: 10, weight: .bold, design: .rounded))
                                    .foregroundColor(idx == 0 ? .white : .white.opacity(0.4))
                                    .frame(width: 16)
                                
                                Text(candidate.name)
                                    .font(.system(size: 12, weight: idx == 0 ? .bold : .regular))
                                    .foregroundColor(idx == 0 ? .white : .white.opacity(0.5))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                
                                // Mini bar
                                GeometryReader { geo in
                                    ZStack(alignment: .leading) {
                                        Capsule().fill(Color.white.opacity(0.08))
                                        Capsule()
                                            .fill(idx == 0
                                                  ? LinearGradient(colors: [.green, .cyan], startPoint: .leading, endPoint: .trailing)
                                                  : LinearGradient(colors: [.white.opacity(0.15), .white.opacity(0.08)], startPoint: .leading, endPoint: .trailing))
                                            .frame(width: geo.size.width * CGFloat(max(0, min(1, candidate.similarity))))
                                    }
                                }
                                .frame(width: 80, height: 4)
                                
                                Text("\(Int(candidate.similarity * 100))%")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(idx == 0 ? .white.opacity(0.7) : .white.opacity(0.3))
                                    .frame(width: 32, alignment: .trailing)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
            }
            .padding(.top, 4)

            // Action Buttons
            if let candidate = face.candidates.first {
                actionButtonsView(for: candidate)
                    .padding(.horizontal, 20)
                    .padding(.bottom, geometry.safeAreaInsets.bottom > 0 ? 16 : 12)
            }
        }
        .frame(maxWidth: min(geometry.size.width - 32, 400))
        .background(
            RoundedRectangle(cornerRadius: 28)
                .fill(.ultraThinMaterial)
                .shadow(color: .black.opacity(0.3), radius: 20, y: -5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: face.name)
    }

    private func actionButtonsView(for candidate: FaceRecognitionViewModel.Candidate) -> some View {
        let isVisitor = viewModel.store.users.first(where: { $0.name == candidate.name })?.userType == .visitor
        let status = viewModel.store.getTodayStatus(for: candidate.name)
        // Cooldown: 1 minute after check-in before showing check-out
        let cooldownActive: Bool = {
            if status == .checkedIn, let checkInTime = lastCheckInTime {
                return Date().timeIntervalSince(checkInTime) < 60
            }
            return false
        }()

        // Smile unlock check
        let smileOK = !requireSmile || viewModel.smileConfidence > 0.8

        return VStack(spacing: 10) {
            if isVisitor {
                // Visitor: show call button only
                HStack(spacing: 15) {
                    Button {
                        // Play notification sound + haptic
                        AudioServicesPlaySystemSound(1315) // Tri-tone notification
                        let generator = UINotificationFeedbackGenerator()
                        generator.notificationOccurred(.success)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "bell.fill")
                            Text("呼び出し")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: [.orange, .yellow.opacity(0.8)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                    }
                }
                .padding(.horizontal, 25)
                .padding(.top, 10)
                .transition(.opacity)
            } else {
                // Employee: show attendance buttons
                // Smile progress (only when smile required and not yet smiling)
                if requireSmile && !smileOK && status != .checkedOut {
                    HStack(spacing: 8) {
                        Image(systemName: "face.smiling")
                            .foregroundColor(.yellow)
                        Text("笑顔で認証")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(.white.opacity(0.7))
                        
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.1))
                                Capsule()
                                    .fill(LinearGradient(colors: [.yellow, .orange], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: geo.size.width * CGFloat(min(1, viewModel.smileConfidence / 0.8)))
                            }
                        }
                        .frame(width: 80, height: 6)
                    }
                    .padding(.horizontal, 25)
                }
                
                HStack(spacing: 15) {
                if status == .notCheckedIn {
                    Button {
                        selectedCandidate = candidate
                        attendanceType = .checkIn
                        showingAttendanceConfirm = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: smileOK ? "sunrise.fill" : "lock.fill")
                            Text("出勤")
                        }
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(
                                colors: smileOK ? [.blue, .cyan] : [.gray.opacity(0.3), .gray.opacity(0.2)],
                                startPoint: .leading, endPoint: .trailing
                            )
                        )
                        .cornerRadius(16)
                    }
                    .disabled(!smileOK)
                } else if status == .checkedIn {
                    if cooldownActive {
                        // Cooldown message
                        HStack(spacing: 8) {
                            Image(systemName: "clock.fill")
                            Text("出勤済み")
                        }
                        .font(.headline)
                        .foregroundColor(.white.opacity(0.6))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.green.opacity(0.15))
                        .cornerRadius(16)
                    } else {
                        Button {
                            selectedCandidate = candidate
                            attendanceType = .checkOut
                            showingAttendanceConfirm = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: smileOK ? "sunset.fill" : "lock.fill")
                                Text("退勤")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .background(
                                LinearGradient(
                                    colors: smileOK ? [.orange, .red] : [.gray.opacity(0.3), .gray.opacity(0.2)],
                                    startPoint: .leading, endPoint: .trailing
                                )
                            )
                            .cornerRadius(16)
                        }
                        .disabled(!smileOK)
                    }
                } else {
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                        Text("本日の勤務完了")
                    }
                    .font(.headline)
                    .foregroundColor(.white.opacity(0.7))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                    .background(Color.white.opacity(0.1))
                    .cornerRadius(16)
                }
            }
                .padding(.horizontal, 25)
                .padding(.top, 10)
                .transition(.opacity)
            }
        }
    }

    private var statusMessageView: some View {
        HStack(spacing: 12) {
            Image(systemName: "faceid")
                .font(.title2)
            Text(viewModel.authStatus)
                .font(.subheadline.bold())
        }
        .foregroundColor(.white)
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial)
        .cornerRadius(25)
        .padding(.bottom, 50)
    }

    // MARK: - Success Overlay
    private var successOverlayView: some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    withAnimation { showingSuccessOverlay = false }
                    selectedCandidate = nil
                }

            VStack(spacing: 20) {
                // Icon
                Image(systemName: attendanceType == .checkIn ? "sunrise.fill" : "sunset.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(
                        attendanceType == .checkIn
                        ? LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom)
                    )
                    .symbolEffect(.bounce, value: showingSuccessOverlay)

                Text(attendanceType == .checkIn ? "出勤完了" : "退勤完了")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Text(attendanceMessage)
                    .font(.system(size: 14))
                    .foregroundColor(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
            }
            .padding(36)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(.ultraThinMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .stroke(Color.white.opacity(0.1), lineWidth: 1)
            )
            .padding(40)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
        .onAppear {
            // Auto-dismiss after 3 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                withAnimation { showingSuccessOverlay = false }
                selectedCandidate = nil
            }
        }
    }

    // MARK: - Floating Register Button
    var floatingRegisterButton: some View {
        VStack {
            Spacer()
            HStack {
                // DB Reset Button
                Button {
                    showingResetConfirm = true
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 50, height: 50)
                        .background(
                            LinearGradient(colors: [.red, .orange], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(Circle())
                        .shadow(color: .red.opacity(0.4), radius: 8, y: 4)
                }
                .padding(.leading, 25)
                
                Spacer()
                
                // Register Button
                Button {
                    showingFaceRegistration = true
                } label: {
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 60, height: 60)
                        .background(
                            LinearGradient(colors: [.blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                        .clipShape(Circle())
                        .shadow(color: .blue.opacity(0.5), radius: 10, y: 5)
                }
                .padding(.trailing, 25)
            }
            .padding(.bottom, 100)
        }
        .alert("データ初期化", isPresented: $showingResetConfirm) {
            Button("全削除", role: .destructive) {
                viewModel.store.resetAllData()
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("全ての登録データと出退勤記録を削除しますか？\nこの操作は元に戻せません。")
        }
    }

    // MARK: - Helper Methods
    private func processAttendance() {
        guard let candidate = selectedCandidate else { return }

        let status = viewModel.store.getTodayStatus(for: candidate.name)

        if status == .notCheckedIn {
            viewModel.store.checkIn(userName: candidate.name)
            attendanceType = .checkIn
            attendanceMessage = "\(candidate.name)さんの出勤を\n記録しました"
        } else if status == .checkedIn {
            viewModel.store.checkOut(userName: candidate.name)
            attendanceType = .checkOut
            attendanceMessage = "\(candidate.name)さんの退勤を\n記録しました"
        } else {
            // Already checked out — do nothing
            selectedCandidate = nil
            return
        }

        // API call
        Task {
            do {
                if attendanceType == .checkIn {
                    _ = try await apiService.checkIn(userNo: "", userName: candidate.name)
                } else {
                    _ = try await apiService.checkOut(userNo: "", userName: candidate.name)
                }
            } catch {
                print("API Error: \(error)")
            }
        }

        // Record time for cooldown
        if attendanceType == .checkIn {
            lastCheckInTime = Date()
        } else if attendanceType == .checkOut {
            lastCheckOutTime = Date()
        }

        // Haptic
        let notification = UINotificationFeedbackGenerator()
        notification.notificationOccurred(.success)

        withAnimation(.spring()) {
            showingSuccessOverlay = true
        }

        viewModel.resetAutoAttendance()
    }

    func convertPoint(_ pt: CGPoint, to size: CGSize) -> CGPoint {
        // bufferSize already accounts for rotation (videoRotationAngle is set on output connection)
        let videoSize = viewModel.bufferSize == .zero ? CGSize(width: 480, height: 640) : viewModel.bufferSize
        
        let scaleX = size.width / videoSize.width
        let scaleY = size.height / videoSize.height
        let scale = max(scaleX, scaleY) // aspect fill
        
        let displayWidth = videoSize.width * scale
        let displayHeight = videoSize.height * scale
        
        let offsetX = (displayWidth - size.width) / 2
        let offsetY = (displayHeight - size.height) / 2
        
        // Vision: (0,0) = bottom-left, SwiftUI: (0,0) = top-left
        return CGPoint(
            x: pt.x * displayWidth - offsetX,
            y: (1.0 - pt.y) * displayHeight - offsetY
        )
    }

    func convertRect(_ rect: CGRect, to size: CGSize) -> CGRect {
        // bufferSize already accounts for rotation
        let videoSize = viewModel.bufferSize == .zero ? CGSize(width: 480, height: 640) : viewModel.bufferSize
        
        let scaleX = size.width / videoSize.width
        let scaleY = size.height / videoSize.height
        let scale = max(scaleX, scaleY) // aspect fill
        
        let displayWidth = videoSize.width * scale
        let displayHeight = videoSize.height * scale
        
        let offsetX = (displayWidth - size.width) / 2
        let offsetY = (displayHeight - size.height) / 2
        
        return CGRect(
            x: rect.origin.x * displayWidth - offsetX,
            y: (1.0 - rect.origin.y - rect.height) * displayHeight - offsetY,
            width: rect.width * displayWidth,
            height: rect.height * displayHeight
        )
    }
}

// MARK: - Supporting Views

struct EnhancedCandidateCard: View {
    let candidate: FaceRecognitionViewModel.Candidate
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: {
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.impactOccurred()
            action()
        }) {
            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: statusColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 65, height: 65)

                    Text(String(candidate.name.prefix(1)))
                        .font(.title)
                        .bold()
                        .foregroundColor(.white)

                    // Status indicator
                    Circle()
                        .fill(statusIndicatorColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().stroke(.white, lineWidth: 2)
                        )
                        .offset(x: 22, y: 22)
                }

                VStack(spacing: 4) {
                    Text(candidate.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    HStack(spacing: 4) {
                        Text("\(Int(candidate.similarity * 100))%")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text("•")
                            .foregroundColor(.secondary)

                        Text(candidate.status.rawValue)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(statusIndicatorColor)
                    }
                }
            }
            .frame(width: 110, height: 140)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color.white.opacity(isSelected ? 0.15 : 0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 20)
                            .stroke(isSelected ? statusIndicatorColor : Color.white.opacity(0.1), lineWidth: isSelected ? 2 : 1)
                    )
            )
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private var statusColors: [Color] {
        switch candidate.status {
        case .notCheckedIn: return [.orange.opacity(0.6), .yellow.opacity(0.3)]
        case .checkedIn: return [.green.opacity(0.6), .cyan.opacity(0.3)]
        case .checkedOut: return [.blue.opacity(0.6), .purple.opacity(0.3)]
        }
    }

    private var statusIndicatorColor: Color {
        switch candidate.status {
        case .notCheckedIn: return .orange
        case .checkedIn: return .green
        case .checkedOut: return .blue
        }
    }
}

// MARK: - Stats View
struct StatsView: View {
    @ObservedObject var viewModel: FaceRecognitionViewModel
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // Chart Section
                VStack(alignment: .leading, spacing: 15) {
                    Text("주간 출근 현황")
                        .font(.headline)
                    
                    Chart(viewModel.store.weeklyStats) { stat in
                        BarMark(
                            x: .value("Day", stat.day),
                            y: .value("Count", stat.count)
                        )
                        .foregroundStyle(LinearGradient(colors: [.blue, .cyan], startPoint: .bottom, endPoint: .top))
                        .cornerRadius(5)
                    }
                    .frame(height: 200)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(15)
                .padding()

                List {
                    Section("최근 활동") {
                        ForEach(viewModel.store.attendanceLogs.prefix(10)) { log in
                            HStack {
                                Image(systemName: log.isCheckIn ? "sunrise.fill" : "sunset.fill")
                                    .foregroundColor(log.isCheckIn ? .orange : .blue)
                                VStack(alignment: .leading) {
                                    Text(log.userName)
                                        .font(.headline)
                                    Text(log.timestamp, style: .time)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(log.isCheckIn ? "出勤" : "退勤")
                                    .font(.caption.bold())
                                    .padding(4)
                                    .background(log.isCheckIn ? Color.orange.opacity(0.2) : Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Dashboard")
            .toolbar {
                Button("閉じる") { dismiss() }
            }
        }
    }
}

// MARK: - Enhanced User List View
struct EnhancedUserListView: View {
    @ObservedObject var store: FaceVectorStore
    @Environment(\.dismiss) var dismiss
    @State private var searchText = ""

    var filteredUsers: [FaceUser] {
        if searchText.isEmpty {
            return store.users
        }
        return store.users.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredUsers) { user in
                    UserRowView(user: user, status: store.getTodayStatus(for: user.name))
                }
                .onDelete(perform: deleteUsers)
            }
            .searchable(text: $searchText, prompt: "ユーザーを検索")
            .navigationTitle("登録ユーザー")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("\(store.users.count)名")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func deleteUsers(at offsets: IndexSet) {
        let usersToDelete = offsets.map { filteredUsers[$0] }
        for user in usersToDelete {
            if let index = store.users.firstIndex(where: { $0.id == user.id }) {
                store.deleteUser(at: IndexSet(integer: index))
            }
        }
    }
}

struct UserRowView: View {
    let user: FaceUser
    let status: UserAttendanceStatus

    var body: some View {
        HStack(spacing: 15) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [.blue.opacity(0.5), .purple.opacity(0.3)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 50, height: 50)

                Text(user.initials)
                    .font(.headline)
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(user.name)
                    .font(.headline)

                HStack(spacing: 8) {
                    Text(user.department)
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("•")
                        .foregroundColor(.secondary)

                    Text("\(user.faceSignatures.count)個のデータ")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 4) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                    Text(status.rawValue)
                        .font(.caption)
                        .foregroundColor(statusColor)
                }

                if let lastSeen = user.lastSeenAt {
                    Text(lastSeen.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch status {
        case .notCheckedIn: return .orange
        case .checkedIn: return .green
        case .checkedOut: return .blue
        }
    }
}

// MARK: - Enhanced History List View
struct EnhancedHistoryListView: View {
    @ObservedObject var store: FaceVectorStore
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab Picker
                Picker("", selection: $selectedTab) {
                    Text("本日").tag(0)
                    Text("履歴").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    todayAttendanceView
                } else {
                    historyView
                }
            }
            .navigationTitle("出退勤記録")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if selectedTab == 0 {
                        Button("リセット", role: .destructive) {
                            store.clearTodayAttendance()
                        }
                        .foregroundColor(.red)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private var todayAttendanceView: some View {
        List {
            // Summary Section
            Section {
                HStack {
                    SummaryCard(
                        title: "出勤",
                        count: store.todayAttendance.values.filter { $0.isCheckedIn }.count,
                        color: .green
                    )
                    SummaryCard(
                        title: "退勤",
                        count: store.todayAttendance.values.filter { $0.isCheckedOut }.count,
                        color: .blue
                    )
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Today's Records
            Section("本日の記録") {
                ForEach(Array(store.todayAttendance.values).sorted(by: { ($0.checkInTime ?? Date()) > ($1.checkInTime ?? Date()) }), id: \.id) { entry in
                    TodayAttendanceRow(entry: entry)
                }
            }
        }
    }

    private var historyView: some View {
        List(store.attendanceLogs) { log in
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(log.userName)
                        .font(.headline)

                    Text(log.timestamp.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                HStack(spacing: 6) {
                    Image(systemName: log.isCheckIn ? "sunrise.fill" : "sunset.fill")
                        .foregroundColor(log.isCheckIn ? .orange : .blue)
                    Text(log.isCheckIn ? "出勤" : "退勤")
                        .font(.caption)
                        .foregroundColor(log.isCheckIn ? .orange : .blue)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule().fill(log.isCheckIn ? Color.orange.opacity(0.1) : Color.blue.opacity(0.1))
                )
            }
        }
    }
}

struct SummaryCard: View {
    let title: String
    let count: Int
    let color: Color

    var body: some View {
        VStack(spacing: 8) {
            Text("\(count)")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(color)

            Text(title)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
        .background(color.opacity(0.1))
        .cornerRadius(15)
    }
}

struct TodayAttendanceRow: View {
    let entry: AttendanceEntry

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.userName)
                    .font(.headline)

                HStack(spacing: 12) {
                    Label(entry.checkInTimeFormatted, systemImage: "sunrise.fill")
                        .font(.caption)
                        .foregroundColor(.orange)

                    if entry.isCheckedOut {
                        Label(entry.checkOutTimeFormatted, systemImage: "sunset.fill")
                            .font(.caption)
                            .foregroundColor(.blue)
                    }
                }
            }

            Spacer()

            if entry.isComplete {
                VStack(alignment: .trailing, spacing: 4) {
                    Text(entry.workDurationFormatted)
                        .font(.subheadline.bold())
                        .foregroundColor(.green)

                    Text("完了")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            } else if entry.isCheckedIn {
                Text("勤務中")
                    .font(.caption)
                    .foregroundColor(.green)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.green.opacity(0.1))
                    .cornerRadius(10)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Settings View
struct SettingsView: View {
    @ObservedObject var viewModel: FaceRecognitionViewModel
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = 0
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showingFileImporter = false
    @State private var showingFaceRegistration = false
    @AppStorage("requireSmileForAttendance") private var requireSmile = true

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab Picker
                Picker("", selection: $selectedTab) {
                    Text("出退勤").tag(0)
                    Text("メンバー").tag(1)
                    Text("設定").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()

                // Content
                switch selectedTab {
                case 0:
                    attendanceTabView
                case 1:
                    membersTabView
                default:
                    settingsTabView
                }
            }
            .navigationTitle("RSP管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("閉じる") { dismiss() }
                }
            }
            .sheet(isPresented: $showingShareSheet) {
                ShareSheet(activityItems: shareItems)
            }
            .fileImporter(isPresented: $showingFileImporter, allowedContentTypes: [.database, .data]) { result in
                handleFileImport(result)
            }
            .alert("通知", isPresented: $showAlert) {
                Button("OK", role: .cancel) { }
            } message: {
                Text(alertMessage)
            }
            .fullScreenCover(isPresented: $showingFaceRegistration) {
                FaceRegistrationView(viewModel: viewModel)
            }
        }
    }

    // MARK: - Attendance Tab
    private var attendanceTabView: some View {
        List {
            // Today Summary
            Section {
                HStack(spacing: 20) {
                    SummaryCard(
                        title: "出勤",
                        count: viewModel.store.todayAttendance.values.filter { $0.isCheckedIn }.count,
                        color: .green
                    )
                    SummaryCard(
                        title: "退勤",
                        count: viewModel.store.todayAttendance.values.filter { $0.isCheckedOut }.count,
                        color: .blue
                    )
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            // Today's Records
            Section("本日の記録") {
                if viewModel.store.todayAttendance.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "tray")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("まだ記録がありません")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 30)
                        Spacer()
                    }
                } else {
                    ForEach(Array(viewModel.store.todayAttendance.values).sorted(by: { ($0.checkInTime ?? Date()) > ($1.checkInTime ?? Date()) }), id: \.id) { entry in
                        TodayAttendanceRow(entry: entry)
                    }
                }
            }

            // History
            Section("最近の履歴") {
                ForEach(viewModel.store.attendanceLogs.prefix(20)) { log in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(log.userName)
                                .font(.subheadline.bold())
                            Text(log.timestamp.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        HStack(spacing: 6) {
                            Image(systemName: log.isCheckIn ? "sunrise.fill" : "sunset.fill")
                                .foregroundColor(log.isCheckIn ? .orange : .blue)
                            Text(log.isCheckIn ? "出勤" : "退勤")
                                .font(.caption)
                                .foregroundColor(log.isCheckIn ? .orange : .blue)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule().fill(log.isCheckIn ? Color.orange.opacity(0.1) : Color.blue.opacity(0.1))
                        )
                    }
                }
            }
        }
    }

    // MARK: - Members Tab
    private var membersTabView: some View {
        List {
            // Add New Member Button
            Section {
                Button {
                    showingFaceRegistration = true
                } label: {
                    HStack {
                        Image(systemName: "person.badge.plus")
                            .font(.title2)
                            .foregroundColor(.blue)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("新規メンバー登録")
                                .font(.headline)
                                .foregroundColor(.primary)
                            Text("顔データを登録して出退勤を自動化")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 8)
                }
            }

            // Member List
            Section("登録メンバー (\(viewModel.store.users.count)名)") {
                if viewModel.store.users.isEmpty {
                    HStack {
                        Spacer()
                        VStack(spacing: 10) {
                            Image(systemName: "person.3")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("登録されたメンバーがいません")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 30)
                        Spacer()
                    }
                } else {
                    ForEach(viewModel.store.users) { user in
                        UserRowView(user: user, status: viewModel.store.getTodayStatus(for: user.name))
                    }
                    .onDelete(perform: viewModel.store.deleteUser)
                }
            }
        }
    }

    // MARK: - Settings Tab
    private var settingsTabView: some View {
        List {
            Section("データ管理") {
                Button {
                    viewModel.backupData()
                    shareItems = [viewModel.store.backupURL]
                    showingShareSheet = true
                } label: {
                    Label("バックアップ・エクスポート", systemImage: "square.and.arrow.up")
                }

                Button {
                    showingFileImporter = true
                } label: {
                    Label("ファイルから復元", systemImage: "square.and.arrow.down")
                }
            }

            Section("情報") {
                HStack {
                    Text("システム名")
                    Spacer()
                    Text("RSP自動出勤システム")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("登録ユーザー数")
                    Spacer()
                    Text("\(viewModel.store.users.count)名")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("本日の出勤者")
                    Spacer()
                    Text("\(viewModel.store.todayAttendance.count)名")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Text("バージョン")
                    Spacer()
                    Text("1.0.0")
                        .foregroundColor(.secondary)
                }
            }

            Section("認証設定") {
                Toggle(isOn: $requireSmile) {
                    Label("笑顔認証", systemImage: "face.smiling")
                }
                .tint(.orange)
                
                if requireSmile {
                    Text("出退勤ボタンを押す前に笑顔を検出する必要があります")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("顔管理") {
                Button {
                    showingFaceRegistration = true
                } label: {
                    Label("新しい顔を登録", systemImage: "person.badge.plus")
                }
            }

            Section("危険な操作") {
                Button(role: .destructive) {
                    viewModel.store.clearTodayAttendance()
                    alertMessage = "本日の出退勤記録をリセットしました"
                    showAlert = true
                } label: {
                    Label("本日の記録をリセット", systemImage: "arrow.counterclockwise")
                }

                Button(role: .destructive) {
                    viewModel.store.clearLogs()
                    alertMessage = "履歴を全て削除しました"
                    showAlert = true
                } label: {
                    Label("履歴を全て削除", systemImage: "trash")
                }

                Button(role: .destructive) {
                    viewModel.store.resetAllData()
                    alertMessage = "全ての登録データと出退勤記録を削除しました"
                    showAlert = true
                } label: {
                    Label("DB全初期化", systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
    }

    private func handleFileImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                if url.startAccessingSecurityScopedResource() {
                    defer { url.stopAccessingSecurityScopedResource() }
                    let backupURL = viewModel.store.backupURL
                    if FileManager.default.fileExists(atPath: backupURL.path) {
                        try FileManager.default.removeItem(at: backupURL)
                    }
                    try FileManager.default.copyItem(at: url, to: backupURL)
                    viewModel.restoreData()
                    alertMessage = "データを復元しました"
                    showAlert = true
                }
            } catch {
                alertMessage = "復元に失敗しました: \(error.localizedDescription)"
                showAlert = true
            }
        case .failure(let error):
            alertMessage = "ファイル選択に失敗しました: \(error.localizedDescription)"
            showAlert = true
        }
    }
}

// MARK: - Reusable Components

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    let rotationAngle: CGFloat
    var faces: [FaceRecognitionViewModel.RecognizedFace] = []
    var isLivenessVerified: Bool = false

    func makeUIView(context: Context) -> PreviewUIView {
        let view = PreviewUIView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        
        let angle = rotationAngle
        DispatchQueue.main.async {
            if let connection = view.videoPreviewLayer.connection {
                connection.videoRotationAngle = angle
            }
        }
        return view
    }

    func updateUIView(_ uiView: PreviewUIView, context: Context) {
        if uiView.videoPreviewLayer.session != session {
            uiView.videoPreviewLayer.session = session
        }
        
        if let connection = uiView.videoPreviewLayer.connection {
            if connection.videoRotationAngle != rotationAngle {
                connection.videoRotationAngle = rotationAngle
            }
            if !connection.isEnabled {
                connection.isEnabled = true
            }
        }
        
        // Update face overlay
        uiView.updateFaces(faces, isLivenessVerified: isLivenessVerified, rotationAngle: rotationAngle)
    }

    class PreviewUIView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
        
        private let overlayLayer = CALayer()
        
        override init(frame: CGRect) {
            super.init(frame: frame)
            overlayLayer.frame = bounds
            layer.addSublayer(overlayLayer)
        }
        
        required init?(coder: NSCoder) { fatalError() }
        
        
        override func layoutSubviews() {
            super.layoutSubviews()
            videoPreviewLayer.frame = bounds
            overlayLayer.frame = bounds
            
            if let connection = videoPreviewLayer.connection, !connection.isEnabled {
                connection.isEnabled = true
            }
        }
        
        func updateFaces(_ faces: [FaceRecognitionViewModel.RecognizedFace], isLivenessVerified: Bool, rotationAngle: CGFloat = 90) {
            overlayLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
            
            let layerW = bounds.width
            let layerH = bounds.height
            guard layerW > 0, layerH > 0 else { return }
            
            // Buffer dims after rotation (base: HD 1280×720)
            let bufW: CGFloat = (rotationAngle == 0 || rotationAngle == 180) ? 1280 : 720
            let bufH: CGFloat = (rotationAngle == 0 || rotationAngle == 180) ? 720 : 1280
            
            // Aspect-fill scaling
            let scale = max(layerW / bufW, layerH / bufH)
            let dispW = bufW * scale
            let dispH = bufH * scale
            let offX = (dispW - layerW) / 2
            let offY = (dispH - layerH) / 2
            
            // Vision (0,0)=bottom-left → Layer (0,0)=top-left
            func v2l(_ p: CGPoint) -> CGPoint {
                CGPoint(x: p.x * dispW - offX, y: (1.0 - p.y) * dispH - offY)
            }
            
            for face in faces {
                let isRecognized = face.name != "未認証" && !face.name.isEmpty && face.name != "認証中..."
                let color: UIColor = isRecognized ? .systemGreen : .cyan
                
                // Bounding box
                let tl = v2l(CGPoint(x: face.rect.minX, y: face.rect.maxY))
                let br = v2l(CGPoint(x: face.rect.maxX, y: face.rect.minY))
                let layerRect = CGRect(x: tl.x, y: tl.y, width: br.x - tl.x, height: br.y - tl.y)
                
                if isRecognized {
                    drawCorners(in: layerRect.insetBy(dx: -4, dy: -4), color: color.withAlphaComponent(0.2), cornerLength: 30, lineWidth: 5)
                }
                drawCorners(in: layerRect, color: color, cornerLength: 25, lineWidth: 3)
                
                // Landmarks
                for (key, points) in face.landmarks {
                    guard !points.isEmpty else { continue }
                    let (op, lw): (CGFloat, CGFloat) = {
                        switch key {
                        case "leftEye", "rightEye": return (0.6, 1.5)
                        case "nose":                return (0.35, 1.0)
                        case "lips":                return (0.5, 1.2)
                        case "outer":               return (0.15, 0.8)
                        default:                    return (0.2, 1.0)
                        }
                    }()
                    let path = UIBezierPath()
                    let pts = points.map { v2l($0) }
                    if let f = pts.first {
                        path.move(to: f)
                        for i in 1..<pts.count { path.addLine(to: pts[i]) }
                    }
                    let sl = CAShapeLayer()
                    sl.path = path.cgPath
                    sl.strokeColor = color.withAlphaComponent(op).cgColor
                    sl.fillColor = UIColor.clear.cgColor
                    sl.lineWidth = lw
                    sl.lineCap = .round; sl.lineJoin = .round
                    overlayLayer.addSublayer(sl)
                }
                
                // Name label above box
                if !face.name.isEmpty {
                    let txt = face.name == "未認証" ? "UNKNOWN" : "\(face.name) \(face.score)%"
                    let tl = CATextLayer()
                    tl.string = txt; tl.fontSize = 13
                    tl.font = UIFont.systemFont(ofSize: 13, weight: .bold)
                    tl.foregroundColor = UIColor.white.cgColor
                    tl.backgroundColor = color.withAlphaComponent(0.75).cgColor
                    tl.cornerRadius = 8; tl.masksToBounds = true
                    tl.alignmentMode = .center; tl.contentsScale = UITraitCollection.current.displayScale
                    let w = max(layerRect.width, 100)
                    tl.frame = CGRect(x: layerRect.midX - w/2, y: layerRect.minY - 34, width: w, height: 26)
                    overlayLayer.addSublayer(tl)
                }
                
                // Liveness badge
                if isLivenessVerified && isRecognized {
                    let s: CGFloat = 26
                    let bl = CATextLayer()
                    bl.string = "✓"; bl.fontSize = 16
                    bl.foregroundColor = UIColor.white.cgColor
                    bl.backgroundColor = color.cgColor
                    bl.cornerRadius = s/2; bl.masksToBounds = true
                    bl.alignmentMode = .center; bl.contentsScale = UITraitCollection.current.displayScale
                    bl.frame = CGRect(x: layerRect.maxX - s/2, y: layerRect.minY - s/2, width: s, height: s)
                    overlayLayer.addSublayer(bl)
                }
            }
        }
        
        private func drawCorners(in rect: CGRect, color: UIColor, cornerLength: CGFloat = 25, lineWidth: CGFloat = 3) {
            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                (CGPoint(x: rect.minX, y: rect.minY + cornerLength),
                 CGPoint(x: rect.minX, y: rect.minY),
                 CGPoint(x: rect.minX + cornerLength, y: rect.minY)),
                (CGPoint(x: rect.maxX - cornerLength, y: rect.minY),
                 CGPoint(x: rect.maxX, y: rect.minY),
                 CGPoint(x: rect.maxX, y: rect.minY + cornerLength)),
                (CGPoint(x: rect.minX, y: rect.maxY - cornerLength),
                 CGPoint(x: rect.minX, y: rect.maxY),
                 CGPoint(x: rect.minX + cornerLength, y: rect.maxY)),
                (CGPoint(x: rect.maxX - cornerLength, y: rect.maxY),
                 CGPoint(x: rect.maxX, y: rect.maxY),
                 CGPoint(x: rect.maxX, y: rect.maxY - cornerLength))
            ]
            
            for (start, corner, end) in corners {
                let path = UIBezierPath()
                path.move(to: start)
                path.addLine(to: corner)
                path.addLine(to: end)
                
                let shapeLayer = CAShapeLayer()
                shapeLayer.path = path.cgPath
                shapeLayer.strokeColor = color.cgColor
                shapeLayer.fillColor = UIColor.clear.cgColor
                shapeLayer.lineWidth = lineWidth
                shapeLayer.lineCap = .round
                shapeLayer.lineJoin = .round
                overlayLayer.addSublayer(shapeLayer)
            }
        }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(response: 0.2), value: configuration.isPressed)
    }
}

struct BlurView: UIViewRepresentable {
    var style: UIBlurEffect.Style

    func makeUIView(context: Context) -> UIVisualEffectView {
        UIVisualEffectView(effect: UIBlurEffect(style: style))
    }

    func updateUIView(_ uiView: UIVisualEffectView, context: Context) {}
}

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension View {
    func cornerRadius(_ radius: CGFloat, corners: UIRectCorner) -> some View {
        clipShape(RoundedCorner(radius: radius, corners: corners))
    }
}

struct RoundedCorner: Shape {
    var radius: CGFloat = .infinity
    var corners: UIRectCorner = .allCorners

    func path(in rect: CGRect) -> Path {
        let path = UIBezierPath(roundedRect: rect, byRoundingCorners: corners, cornerRadii: CGSize(width: radius, height: radius))
        return Path(path.cgPath)
    }
}

extension ContentView {
    // MARK: - Visitor Overlay
    private func visitorRegistrationOverlay(geometry: GeometryProxy) -> some View {
        ZStack {
            Color.black.opacity(0.6)
                .ignoresSafeArea()
                .onTapGesture {
                    showingVisitorRegistration = false
                }
            
            VStack(spacing: 24) {
                VStack(spacing: 8) {
                    Text("방문객 등록")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    
                    Text("방문 정보를 입력해 주세요")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.6))
                }
                .padding(.top, 10)
                
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("성함")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.blue.opacity(0.8))
                        
                        TextField("성함을 입력하세요", text: $visitorName)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(12)
                            .foregroundColor(.white)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("방문 목적")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.blue.opacity(0.8))
                        
                        TextField("방문 목적을 입력하세요", text: $visitPurpose)
                            .padding()
                            .background(Color.white.opacity(0.1))
                            .cornerRadius(12)
                            .foregroundColor(.white)
                    }
                }
                
                Button {
                    if !visitorName.isEmpty {
                        viewModel.registerVisitor(name: visitorName, purpose: visitPurpose)
                        showingVisitorRegistration = false
                        visitorName = ""
                        visitPurpose = ""
                        
                        notificationFeedback(.success)
                        withAnimation {
                            showingSuccessOverlay = true
                        }
                    }
                } label: {
                    Text("등록 및 알림 전송")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(
                            LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                        )
                        .cornerRadius(16)
                        .shadow(color: .blue.opacity(0.3), radius: 10, y: 5)
                }
                .padding(.top, 10)
            }
            .padding(32)
            .frame(maxWidth: min(geometry.size.width - 48, 400)) // Adaptive width
            .background(.ultraThinMaterial)
            .cornerRadius(32)
            .overlay(
                RoundedRectangle(cornerRadius: 32)
                    .stroke(Color.white.opacity(0.2), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 40, x: 0, y: 20)
        }
    }

    private func notificationFeedback(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(type)
    }
}
