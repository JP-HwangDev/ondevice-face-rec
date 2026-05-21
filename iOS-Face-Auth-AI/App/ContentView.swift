//
//  ContentView.swift
//  FaceAuthApp
//
//  Created by yon on 2026/01/24.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var cameraPermission = CameraPermissionManager()
    @ObservedObject private var store = EmployeeStore.shared
    @ObservedObject private var attendanceStore = AttendanceStore.shared
    @State private var showCamera = false
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            // MARK: - 탭 1: 홈 (출석 체크)
            homeTab
                .tabItem {
                    Label("출석 체크", systemImage: "camera.fill")
                }
                .tag(0)

            // MARK: - 탭 2: 출석 이력
            AttendanceHistoryView()
                .tabItem {
                    Label("출석 이력", systemImage: "clock.fill")
                }
                .badge(attendanceStore.todayCheckInCount)
                .tag(1)

            // MARK: - 탭 3: 사원 관리
            EmployeeManagementView()
                .tabItem {
                    Label("사원 관리", systemImage: "person.3.fill")
                }
                .badge(store.employees.count)
                .tag(2)

            // MARK: - 탭 4: 설정
            SettingsView()
                .tabItem {
                    Label("설정", systemImage: "gearshape.fill")
                }
                .tag(3)

            #if DEBUG
            // MARK: - 탭 5: 디버그 콘솔
            DebugConsoleView()
                .tabItem {
                    Label("디버그", systemImage: "ladybug.fill")
                }
                .tag(4)
            #endif
        }
        .onChange(of: selectedTab) { _, newTab in
            let tabNames = ["출석 체크", "출석 이력", "사원 관리", "설정", "디버그"]
            let name = newTab < tabNames.count ? tabNames[newTab] : "탭\(newTab)"
        }
        .task {
            DebugLogger.shared.log(category: .general, message: "카메라 권한 요청 시작")
            await cameraPermission.requestPermission()
            DebugLogger.shared.log(category: .general, message: "카메라 권한 결과: \(cameraPermission.permissionGranted ? "허용" : "거부")")
        }
        .fullScreenCover(isPresented: $showCamera) {
            FaceRecognitionView()
        }
    }

    // MARK: - 홈 탭

    private var homeTab: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // 상태 카드
                    statusCard

                    // 출석 체크 버튼
                    attendanceButton

                    // 오늘 출석 현황
                    if !attendanceStore.todayRecords.isEmpty {
                        todayAttendanceSection
                    }

                    // 등록 현황 요약
                    if !store.employees.isEmpty {
                        summarySection
                    }
                }
                .padding()
            }
            .navigationTitle("FaceAuth")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        selectedTab = 2
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }
            }
        }
    }

    // MARK: - 상태 카드

    private var statusCard: some View {
        HStack(spacing: 16) {
            // 카메라 권한 상태
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(cameraPermission.permissionGranted ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                    Text(cameraPermission.permissionGranted ? "카메라 준비됨" : "권한 필요")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(cameraPermission.permissionGranted ? .green : .orange)
                }
                Text("시스템 상태")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 36)

            // 등록 사원 수
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "person.fill.checkmark")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("\(store.employees.count)명 등록")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.blue)
                }
                Text("등록 사원")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 36)

            // 오늘 출석
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text("\(attendanceStore.todayCheckInCount)명 출근")
                        .font(.caption)
                        .fontWeight(.medium)
                        .foregroundStyle(.green)
                }
                Text("오늘 출석")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(16)
    }

    // MARK: - 출석 체크 버튼

    private var attendanceButton: some View {
        Button {
            if cameraPermission.permissionGranted {
                DebugLogger.shared.log(category: .faceAuth, message: "출석 체크 카메라 열기")
                showCamera = true
            } else {
                DebugLogger.shared.log(level: .warning, category: .general, message: "카메라 권한 없음 — 재요청")
                Task { await cameraPermission.requestPermission() }
            }
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .fill(
                        cameraPermission.permissionGranted
                        ? LinearGradient(colors: [.blue, .cyan], startPoint: .topLeading, endPoint: .bottomTrailing)
                        : LinearGradient(colors: [.gray.opacity(0.4), .gray.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                    .frame(height: 180)

                VStack(spacing: 14) {
                    Image(systemName: cameraPermission.permissionGranted ? "camera.fill" : "camera.badge.ellipsis")
                        .font(.system(size: 48))
                        .foregroundStyle(.white)

                    Text(cameraPermission.permissionGranted ? "출석 체크 시작" : "카메라 권한 요청")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)

                    Text(cameraPermission.permissionGranted
                         ? "카메라로 얼굴을 인식해 출석을 체크합니다"
                         : "탭하여 카메라 사용 권한을 허용해주세요")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .padding()
            }
        }
        .buttonStyle(.plain)
        .shadow(color: cameraPermission.permissionGranted ? .blue.opacity(0.3) : .clear,
                radius: 12, x: 0, y: 6)
    }

    // MARK: - 오늘 출석 현황

    private var todayAttendanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("오늘 출석 현황")
                    .font(.headline)
                    .padding(.horizontal, 4)
                Spacer()
                Button {
                    selectedTab = 1
                } label: {
                    Text("전체 보기")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }

            VStack(spacing: 8) {
                ForEach(attendanceStore.todayRecords.prefix(5)) { record in
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(record.type.color.opacity(0.15))
                                .frame(width: 36, height: 36)
                            Image(systemName: record.type.icon)
                                .font(.caption)
                                .foregroundStyle(record.type.color)
                        }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(record.employeeName)
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(record.department)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Text(record.timeString)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }

    // MARK: - 등록 현황 요약

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("등록 현황")
                .font(.headline)
                .padding(.horizontal, 4)

            VStack(spacing: 8) {
                ForEach(store.sortedDepartments.prefix(4), id: \.self) { department in
                    let count = store.departmentGroups[department]?.count ?? 0
                    let total = store.employees.count
                    let ratio = total > 0 ? Double(count) / Double(total) : 0

                    HStack(spacing: 10) {
                        Text(department)
                            .font(.subheadline)
                            .frame(width: 80, alignment: .leading)

                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(Color(.tertiarySystemFill))
                                    .frame(height: 8)
                                Capsule()
                                    .fill(Color.blue.gradient)
                                    .frame(width: geo.size.width * ratio, height: 8)
                            }
                        }
                        .frame(height: 8)

                        Text("\(count)명")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 32, alignment: .trailing)
                    }
                }

                if store.sortedDepartments.count > 4 {
                    Button {
                        selectedTab = 2
                    } label: {
                        Text("전체 \(store.sortedDepartments.count)개 부서 보기")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                    .padding(.top, 4)
                }
            }
            .padding(16)
            .background(Color(.secondarySystemBackground))
            .cornerRadius(16)
        }
    }
}

#Preview {
    ContentView()
}
