import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import Combine
import Charts

struct ContentView: View {
    @StateObject var viewModel = FaceRecognitionViewModel()
    @StateObject var apiService = APIService.shared

    @State private var showingSettings = false
    @State private var showingFaceRegistration = false
    @State private var selectedRegistrationEmployee: Employee? = nil
    @State private var showingSuccessOverlay = false
    @State private var showingPasswordPrompt = false
    @State private var showingStats = false

    // Candidate confirmation
    @State private var pendingName: String = ""
    @State private var pendingType: AttendanceType = .checkIn
    @State private var showingCandidateConfirm = false

    @State private var attendanceMessage = ""
    @State private var attendanceType: AttendanceType = .checkIn
    @State private var passwordInput = ""
    @State private var passwordError = false

    @State private var isScanning = false
    @State private var currentTime = Date()

    @State private var showingConsent = false
    @State private var pendingConsentEmployeeName: String = ""

    private let settingsPassword = "20170201"

    let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var safeAreaTop: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first?.windows
            .first(where: { $0.isKeyWindow })?
            .safeAreaInsets.top ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height

            ZStack {
                // Camera + Background
                backgroundView

                // UI Overlay
                VStack(spacing: 0) {
                    headerView(safeAreaTop: safeAreaTop)
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

                // Settings button — bottom left
                VStack {
                    Spacer()
                    HStack {
                        Button {
                            showingPasswordPrompt = true
                        } label: {
                            Image(systemName: "gearshape.fill")
                                .font(.system(size: 15))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(width: 40, height: 40)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                        .padding(.leading, geometry.safeAreaInsets.leading + 20)
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 20)
                        Spacer()
                    }
                }

                // Success Overlay
                if showingSuccessOverlay {
                    successOverlayView
                        .zIndex(100)
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
        .sheet(isPresented: $showingConsent) {
            ConsentModalView(employeeName: pendingConsentEmployeeName) { name in
                // Save consent and proceed to registration
                viewModel.store.saveConsent(userName: name, consentVersion: "v1.0-2026-06-19")
                selectedRegistrationEmployee = apiService.employees.first { $0.userName == name }
                showingFaceRegistration = true
            } onCancel: {
                // Do nothing
            }
            .presentationDetents([.medium, .large])
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
            FaceRegistrationView(viewModel: viewModel, preselectedEmployee: selectedRegistrationEmployee)
        }
        .onChange(of: showingFaceRegistration) { _, isPresented in
            if !isPresented {
                let registeredName = selectedRegistrationEmployee?.userName ?? ""
                selectedRegistrationEmployee = nil
                viewModel.resetAfterRegistration(employeeName: registeredName)
                viewModel.cameraManager.start()
                viewModel.refreshID = UUID()
            }
        }
        .alert("確認", isPresented: $showingCandidateConfirm) {
            Button(pendingType == .checkIn ? "出勤する" : "退勤する") {
                executeAttendance(name: pendingName, type: pendingType)
            }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("\(pendingName)さん、\(pendingType == .checkIn ? "出勤" : "退勤")しますか？")
        }
        .task {
            await apiService.loadEmployees()
            // Refresh every 60 seconds
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                await apiService.silentRefresh()
            }
        }
        .onChange(of: viewModel.shouldAutoAttendance) { _, shouldShow in
            if shouldShow {
                guard !showingFaceRegistration, !showingSettings else {
                    viewModel.resetAutoAttendance()
                    return
                }
                if let face = viewModel.detectedFaces.first,
                   let candidate = face.candidates.first {
                    let serverStatus = apiService.employee(named: candidate.name)?.serverStatus ?? .notCheckedIn
                    guard serverStatus != .checkedOut else {
                        viewModel.resetAutoAttendance()
                        return
                    }
                    executeAttendance(name: candidate.name, type: serverStatus == .notCheckedIn ? .checkIn : .checkOut)
                }
            }
        }
    }

    // MARK: - Components
    
    private var cameraLayer: some View {
        Group {
            if viewModel.cameraManager.isAuthorized && !showingFaceRegistration && !showingSettings {
                 CameraPreviewView(session: viewModel.cameraManager.session, rotationAngle: viewModel.rotationAngle, faces: viewModel.detectedFaces)
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
                
            }
        }
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
        let emp = apiService.employee(named: face.name)
        let status = emp?.serverStatus ?? .notCheckedIn
        let bottomPad = max(geometry.safeAreaInsets.bottom, 16)

        return VStack(spacing: 0) {
            // ── Row: Avatar + Info + Button ──
            HStack(spacing: 12) {
                // Avatar
                ZStack {
                    Circle()
                        .fill(LinearGradient(
                            colors: status == .checkedIn ? [.green.opacity(0.8), .cyan.opacity(0.6)]
                                  : status == .checkedOut ? [.blue.opacity(0.7), .indigo.opacity(0.6)]
                                  : [Color(.systemGray4), Color(.systemGray5)],
                            startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 38, height: 38)
                    Text(String(face.name.prefix(1)))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                }

                // Name + % + button + status
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(face.name)
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("\(face.score)%")
                            .font(.system(size: 12, weight: .heavy, design: .monospaced))
                            .foregroundColor(face.score >= 85 ? .green : .yellow)
                        compactAttendanceButton(name: face.name, status: status)
                    }

                    if let inn = emp?.workIn, !inn.isEmpty, inn != "0" {
                        HStack(spacing: 6) {
                            Label(inn, systemImage: "sunrise.fill")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.green)
                            if let out = emp?.workOut, !out.isEmpty, out != "0" {
                                Label(out, systemImage: "sunset.fill")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundColor(.orange)
                            }
                        }
                    } else {
                        Text("本日未出勤")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.4))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)

            // ── Candidate list (if >1) ──
            if face.candidates.count > 1 {
                Divider()
                    .background(Color.white.opacity(0.1))
                    .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    ForEach(Array(face.candidates.dropFirst().prefix(3).enumerated()), id: \.element.id) { idx, candidate in
                        let cEmp = apiService.employee(named: candidate.name)
                        let cStatus = cEmp?.serverStatus ?? .notCheckedIn
                        Button {
                            pendingName = candidate.name
                            pendingType = cStatus == .notCheckedIn ? .checkIn : .checkOut
                            showingCandidateConfirm = true
                        } label: {
                            HStack(spacing: 8) {
                                Text("\(idx + 2)")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(.white.opacity(0.3))
                                    .frame(width: 14)
                                Text(candidate.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.white.opacity(0.6))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Text("\(Int(candidate.similarity * 100))%")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundColor(.white.opacity(0.35))
                                Circle()
                                    .fill(cStatus == .checkedIn ? Color.green : cStatus == .checkedOut ? Color.blue : Color(.systemGray4))
                                    .frame(width: 6, height: 6)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .frame(maxWidth: min(geometry.size.width - 48, 340))
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: face.name)
    }

    @ViewBuilder
    private func compactAttendanceButton(name: String, status: ServerAttendanceStatus) -> some View {
        switch status {
        case .notCheckedIn:
            Button { executeAttendance(name: name, type: .checkIn) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sunrise.fill").font(.system(size: 12))
                    Text("出勤").font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

        case .checkedIn:
            Button { executeAttendance(name: name, type: .checkOut) } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sunset.fill").font(.system(size: 12))
                    Text("退勤").font(.system(size: 13, weight: .bold))
                }
                .foregroundColor(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(LinearGradient(colors: [.orange, .red.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                .clipShape(Capsule())
            }
            .buttonStyle(.plain)

        case .checkedOut:
            Text("お疲れ様！")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.6))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.purple.opacity(0.3))
                .clipShape(Capsule())
        }
    }

    @ViewBuilder
    private func attendanceButton(name: String, status: ServerAttendanceStatus) -> some View {
        switch status {
        case .notCheckedIn:
            Button { executeAttendance(name: name, type: .checkIn) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sunrise.fill").font(.title3)
                    Text("出勤する").font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

        case .checkedIn:
            Button { executeAttendance(name: name, type: .checkOut) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "sunset.fill").font(.title3)
                    Text("退勤する").font(.system(size: 17, weight: .bold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(LinearGradient(colors: [.orange, .red.opacity(0.85)], startPoint: .leading, endPoint: .trailing))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)

        case .checkedOut:
            HStack(spacing: 10) {
                Image(systemName: "hands.clap.fill").font(.title3)
                Text("お疲れ様でした！").font(.system(size: 17, weight: .bold))
            }
            .foregroundColor(.white.opacity(0.8))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(LinearGradient(colors: [.purple.opacity(0.5), .indigo.opacity(0.4)], startPoint: .leading, endPoint: .trailing))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    // MARK: - Success Toast
    private var successOverlayView: some View {
        VStack {
            HStack(spacing: 12) {
                Image(systemName: attendanceType == .checkIn ? "sunrise.fill" : "sunset.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(attendanceType == .checkIn
                        ? LinearGradient(colors: [.blue, .cyan], startPoint: .top, endPoint: .bottom)
                        : LinearGradient(colors: [.orange, .red], startPoint: .top, endPoint: .bottom))
                    .symbolEffect(.bounce, value: showingSuccessOverlay)

                VStack(alignment: .leading, spacing: 2) {
                    Text(attendanceType == .checkIn ? "出勤完了" : "退勤完了")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Text(attendanceMessage)
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.65))
                }

                Spacer()

                Button {
                    withAnimation { showingSuccessOverlay = false }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 28, height: 28)
                        .background(Color.white.opacity(0.1))
                        .clipShape(Circle())
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 4)
            .padding(.horizontal, 20)
            .padding(.top, 60)

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                withAnimation(.easeOut) { showingSuccessOverlay = false }
            }
        }
    }

    // MARK: - Helper Methods
    private func executeAttendance(name: String, type: AttendanceType) {
        attendanceType = type
        if type == .checkIn {
            viewModel.store.checkIn(userName: name)
            attendanceMessage = "\(name)さんの出勤を記録しました"
        } else {
            viewModel.store.checkOut(userName: name)
            attendanceMessage = "\(name)さんの退勤を記録しました"
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
            showingSuccessOverlay = true
        }
        viewModel.resetAutoAttendance()
        Task {
            if let emp = apiService.employee(named: name) {
                do {
                    if type == .checkIn {
                        try await apiService.setWorkIn(userNo: emp.userNo, userName: emp.userName)
                    } else {
                        try await apiService.setWorkOut(userNo: emp.userNo, userName: emp.userName)
                    }
                } catch {
                    print("[Attendance] API error: \(error)")
                }
            }
            await apiService.silentRefresh()
        }
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
    
    private func requestRegistration(for employee: Employee) {
        pendingConsentEmployeeName = employee.userName
        showingConsent = true
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

// MARK: - Member Card Row
struct MemberCardRow: View {
    let employee: Employee
    let faceUser: FaceUser?

    private var serverStatus: ServerAttendanceStatus { employee.serverStatus }

    var body: some View {
        HStack(spacing: 14) {
            // Avatar with status ring
            ZStack {
                Circle()
                    .stroke(statusColor.opacity(0.5), lineWidth: 2)
                    .frame(width: 50, height: 50)
                Circle()
                    .fill(faceUser != nil
                        ? LinearGradient(colors: [.blue, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [Color(.systemGray4), Color(.systemGray5)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 44, height: 44)
                Text(employee.initials)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
            }

            // Name & times
            VStack(alignment: .leading, spacing: 3) {
                Text(employee.userName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.primary)
                Text(employee.department)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                // Attendance times
                if let inn = employee.workIn, !inn.isEmpty, inn != "0" {
                    HStack(spacing: 6) {
                        Label(inn, systemImage: "sunrise.fill")
                            .font(.caption2)
                            .foregroundColor(.green)
                        if let out = employee.workOut, !out.isEmpty, out != "0" {
                            Label(out, systemImage: "sunset.fill")
                                .font(.caption2)
                                .foregroundColor(.orange)
                        }
                    }
                }
            }

            Spacer()

            // Right badges
            VStack(alignment: .trailing, spacing: 4) {
                // Server attendance status
                HStack(spacing: 3) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(serverStatus.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(statusColor)
                }

                // Face registration badge
                if faceUser != nil {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.blue.opacity(0.7))
                        Text("顔登録済")
                            .font(.system(size: 10))
                            .foregroundColor(.blue.opacity(0.7))
                    }
                } else {
                    Text("未登録")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.orange)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Color.orange.opacity(0.1))
                        .clipShape(Capsule())
                }
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 11))
                .foregroundColor(Color(.systemGray3))
        }
        .padding(.vertical, 5)
    }

    private var statusColor: Color {
        switch serverStatus {
        case .notCheckedIn: return Color(.systemGray3)
        case .checkedIn:    return .green
        case .checkedOut:   return .blue
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
    @StateObject private var apiService = APIService.shared
    @Environment(\.dismiss) var dismiss
    @State private var selectedTab = 0
    @State private var showAlert = false
    @State private var alertMessage = ""
    @State private var showingShareSheet = false
    @State private var shareItems: [Any] = []
    @State private var showingFileImporter = false
    @State private var showingFaceRegistration = false
    @State private var selectedRegistrationEmployee: Employee? = nil
    @State private var showingConsent = false
    @State private var pendingConsentEmployeeName: String = ""

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
                FaceRegistrationView(viewModel: viewModel, preselectedEmployee: selectedRegistrationEmployee)
            }
            .onChange(of: showingFaceRegistration) { _, isPresented in
                if !isPresented { selectedRegistrationEmployee = nil }
            }
            .sheet(isPresented: $showingConsent) {
                ConsentModalView(employeeName: pendingConsentEmployeeName) { name in
                    viewModel.store.saveConsent(userName: name, consentVersion: "v1.0-2026-06-19")
                    selectedRegistrationEmployee = apiService.employees.first { $0.userName == name }
                    showingFaceRegistration = true
                } onCancel: {
                    // Do nothing
                }
                .presentationDetents([.medium, .large])
            }
            .task {
                await apiService.loadEmployees()
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
        Group {
            if apiService.isLoading {
                VStack(spacing: 16) {
                    Spacer()
                    ProgressView()
                        .scaleEffect(1.3)
                    Text("読み込み中...")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
            } else if let error = apiService.errorMessage {
                VStack(spacing: 20) {
                    Spacer()
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48))
                        .foregroundColor(.orange)
                    Text("サーバーに接続できませんでした")
                        .font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await apiService.loadEmployees() }
                    } label: {
                        Label("再試行", systemImage: "arrow.clockwise")
                            .font(.subheadline.bold())
                            .padding(.horizontal, 24)
                            .padding(.vertical, 10)
                            .background(Color.blue)
                            .foregroundColor(.white)
                            .clipShape(Capsule())
                    }
                    Spacer()
                }
                .padding()
            } else {
                List {
                    ForEach(apiService.employees) { employee in
                        let faceUser = viewModel.store.users.first(where: { $0.name == employee.userName })
                        Button {
                            pendingConsentEmployeeName = employee.userName
                            showingConsent = true
                        } label: {
                            MemberCardRow(employee: employee, faceUser: faceUser)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.insetGrouped)
                .refreshable {
                    await apiService.loadEmployees()
                }
            }
        }
        .navigationTitle("メンバー (\(apiService.employees.count)名)")
        .navigationBarTitleDisplayMode(.inline)
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

            Section("認識精度") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("認識閾値")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", viewModel.matchThreshold))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.blue)
                    }
                    Slider(value: $viewModel.matchThreshold, in: 0.60...0.90, step: 0.01)
                        .tint(.blue)
                        .onChange(of: viewModel.matchThreshold) { _, v in
                            if viewModel.dropThreshold >= v - 0.04 {
                                viewModel.dropThreshold = max(0.50, v - 0.08)
                            }
                        }
                    Text("低い → 認識しやすい（誤認識増）　高い → 厳密（見逃し増）")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("解除閾値")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", viewModel.dropThreshold))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.orange)
                    }
                    Slider(value: $viewModel.dropThreshold, in: 0.50...0.80, step: 0.01)
                        .tint(.orange)
                    Text("認識後にこの値を下回ると未認証に戻る")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("反応速度")
                            .font(.subheadline)
                        Spacer()
                        Text(String(format: "%.2f", viewModel.smoothingAlpha))
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundColor(.green)
                    }
                    Slider(value: $viewModel.smoothingAlpha, in: 0.10...0.60, step: 0.05)
                        .tint(.green)
                    Text("低い → 安定（ゆっくり）　高い → 素早く反応")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)

                Button {
                    viewModel.resetThresholds()
                } label: {
                    Label("デフォルトに戻す (0.70 / 0.60 / 0.25)", systemImage: "arrow.counterclockwise")
                        .font(.subheadline)
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
        uiView.updateFaces(faces, rotationAngle: rotationAngle)
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
        
        func updateFaces(_ faces: [FaceRecognitionViewModel.RecognizedFace], rotationAngle: CGFloat = 90) {
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

struct ShareSheet: UIViewControllerRepresentable {
    var activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: applicationActivities)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
