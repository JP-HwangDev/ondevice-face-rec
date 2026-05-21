//
//  SettingsView.swift
//  FaceAuthApp
//
//  앱 설정 화면
//

import SwiftUI

struct SettingsView: View {
    @ObservedObject private var employeeStore = EmployeeStore.shared
    @ObservedObject private var attendanceStore = AttendanceStore.shared

    @AppStorage("similarity_threshold") private var similarityThreshold = 0.4
    @AppStorage("enable_haptic") private var enableHaptic = true
    @AppStorage("auto_dismiss_camera") private var autoDismissCamera = true
    @AppStorage("show_confidence") private var showConfidence = true

    @State private var showResetConfirm = false
    @State private var showClearAttendanceConfirm = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: - 인식 설정
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("유사도 임계값")
                            Spacer()
                            Text("\(Int(similarityThreshold * 100))%")
                                .foregroundStyle(.blue)
                                .fontWeight(.semibold)
                        }
                        Slider(value: $similarityThreshold, in: 0.2...0.7, step: 0.05)
                            .tint(.blue)
                            .onChange(of: similarityThreshold) { _, newValue in
                                DebugLogger.shared.log(category: .general, message: "설정 변경: 유사도 임계값 → \(Int(newValue * 100))%")
                            }
                        Text("높을수록 엄격하게 판별합니다. 권장: 35~50%")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("인식 설정")
                } footer: {
                    Text("임계값 이하의 매칭 결과는 표시되지 않습니다.")
                }

                // MARK: - 화면 설정
                Section("화면 설정") {
                    Toggle("유사도 퍼센트 표시", isOn: $showConfidence)
                        .onChange(of: showConfidence) { _, newValue in
                            DebugLogger.shared.log(category: .general, message: "설정 변경: 유사도 표시 → \(newValue ? "ON" : "OFF")")
                        }

                    Toggle("햅틱 피드백", isOn: $enableHaptic)
                        .onChange(of: enableHaptic) { _, newValue in
                            DebugLogger.shared.log(category: .general, message: "설정 변경: 햅틱 피드백 → \(newValue ? "ON" : "OFF")")
                        }

                    Toggle("출석 체크 후 카메라 자동 닫기", isOn: $autoDismissCamera)
                        .onChange(of: autoDismissCamera) { _, newValue in
                            DebugLogger.shared.log(category: .general, message: "설정 변경: 카메라 자동 닫기 → \(newValue ? "ON" : "OFF")")
                        }
                }

                // MARK: - 시스템 정보
                Section("시스템 정보") {
                    LabeledContent("등록 사원 수") {
                        Text("\(employeeStore.employees.count)명")
                    }

                    LabeledContent("부서 수") {
                        Text("\(employeeStore.sortedDepartments.count)개")
                    }

                    LabeledContent("총 출석 기록") {
                        Text("\(attendanceStore.records.count)건")
                    }

                    LabeledContent("Core ML 모델") {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(bundledModelName == nil ? Color.orange : Color.green)
                                .frame(width: 8, height: 8)
                            Text(bundledModelName ?? "목업 모드")
                                .font(.subheadline)
                        }
                    }

                    LabeledContent("앱 버전") {
                        Text("1.0.0")
                    }

                    LabeledContent("iOS 최소 버전") {
                        Text("17.0+")
                    }
                }

                // MARK: - 기술 스택
                Section("기술 스택") {
                    techStackRow(name: "SwiftUI", detail: "UI 프레임워크")
                    techStackRow(name: "AVFoundation", detail: "카메라 제어")
                    techStackRow(name: "Vision", detail: "얼굴 감지")
                    techStackRow(name: "Core ML", detail: coreMLDetail)
                    techStackRow(name: "Accelerate", detail: "벡터 유사도 계산")
                    techStackRow(name: "GRDB.swift", detail: "SQLite 로컬 DB")
                }

                // MARK: - 데이터 관리
                Section {
                    Button(role: .destructive) {
                        showClearAttendanceConfirm = true
                    } label: {
                        Label("출석 기록 초기화", systemImage: "trash")
                    }

                    Button(role: .destructive) {
                        showResetConfirm = true
                    } label: {
                        Label("모든 데이터 초기화", systemImage: "exclamationmark.triangle")
                    }
                } header: {
                    Text("데이터 관리")
                } footer: {
                    Text("초기화된 데이터는 복구할 수 없습니다.")
                }
            }
            .navigationTitle("설정")
            .alert("출석 기록 초기화", isPresented: $showClearAttendanceConfirm) {
                Button("취소", role: .cancel) { }
                Button("초기화", role: .destructive) {
                    attendanceStore.deleteAll()
                }
            } message: {
                Text("모든 출석 기록이 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
            }
            .alert("전체 데이터 초기화", isPresented: $showResetConfirm) {
                Button("취소", role: .cancel) { }
                Button("초기화", role: .destructive) {
                    resetAllData()
                }
            } message: {
                Text("사원 정보와 출석 기록이 모두 삭제되고 앱이 초기 상태로 돌아갑니다.")
            }
        }
    }

    private var bundledModelName: String? {
        for candidate in FaceEmbeddingExtractor.supportedModels {
            if Bundle.main.url(forResource: candidate.resourceName, withExtension: "mlmodelc") != nil {
                return candidate.displayName
            }
        }
        return nil
    }

    private var coreMLDetail: String {
        if let bundledModelName {
            return "\(bundledModelName) 추론"
        }
        return "모델 미포함"
    }

    private func techStackRow(name: String, detail: String) -> some View {
        HStack {
            Text(name)
                .font(.subheadline)
                .fontWeight(.medium)
            Spacer()
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resetAllData() {
        DebugLogger.shared.log(level: .warning, category: .database, message: "전체 데이터 초기화 실행", details: "사원: \(employeeStore.employees.count)명, 출석: \(attendanceStore.records.count)건 삭제")
        attendanceStore.deleteAll()
        employeeStore.deleteAll()
    }
}

#Preview {
    SettingsView()
}
