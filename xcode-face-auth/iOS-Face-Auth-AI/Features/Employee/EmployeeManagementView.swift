//
//  EmployeeManagementView.swift
//  FaceAuthApp
//
//  Created by yon on 2026/02/01.
//

import SwiftUI

/// 사원 관리 화면
struct EmployeeManagementView: View {
    @ObservedObject private var store = EmployeeStore.shared
    @State private var showAddEmployee = false
    @State private var searchText = ""
    @State private var selectedDepartment: String?
    @State private var employeeToDelete: Employee?
    @State private var showDeleteConfirm = false
    @State private var selectedEmployee: Employee?

    private var filteredEmployees: [Employee] {
        var result = store.employees

        if let dept = selectedDepartment {
            result = result.filter { $0.department == dept }
        }

        if !searchText.isEmpty {
            result = result.filter {
                $0.name.localizedCaseInsensitiveContains(searchText) ||
                $0.department.localizedCaseInsensitiveContains(searchText)
            }
        }

        return result.sorted { $0.name < $1.name }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.employees.isEmpty {
                    emptyStateView
                } else {
                    employeeListView
                }
            }
            .navigationTitle("사원 관리")
            .searchable(text: $searchText, prompt: "이름 또는 부서 검색")
            .onChange(of: searchText) { _, newValue in
                if !newValue.isEmpty {
                    DebugLogger.shared.log(category: .general, message: "사원 검색: \"\(newValue)\"", details: "결과: \(filteredEmployees.count)명")
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        DebugLogger.shared.log(category: .general, message: "사원 추가 화면 열기")
                        showAddEmployee = true
                    } label: {
                        Image(systemName: "person.badge.plus")
                    }
                }

                if !store.employees.isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        departmentFilterMenu
                    }
                }
            }
            .sheet(isPresented: $showAddEmployee) {
                AddEmployeeView()
            }
            .sheet(item: $selectedEmployee) { employee in
                EmployeeDetailView(employee: employee)
            }
            .alert("사원 삭제", isPresented: $showDeleteConfirm) {
                Button("취소", role: .cancel) { }
                Button("삭제", role: .destructive) {
                    if let employee = employeeToDelete {
                        store.delete(employee)
                    }
                }
            } message: {
                if let employee = employeeToDelete {
                    Text("\(employee.name)님을 삭제하시겠습니까?\n등록된 얼굴 정보도 함께 삭제됩니다.")
                }
            }
        }
    }

    // MARK: - 빈 상태 뷰

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("등록된 사원 없음", systemImage: "person.3.fill")
        } description: {
            Text("사원을 등록하여 얼굴 인식 출석 체크를 시작하세요.")
        } actions: {
            Button {
                showAddEmployee = true
            } label: {
                Text("사원 추가")
                    .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - 사원 목록 뷰

    private var employeeListView: some View {
        List {
            Section {
                statisticsRow
            }

            Section {
                ForEach(filteredEmployees) { employee in
                    EmployeeRow(employee: employee)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            DebugLogger.shared.log(category: .general, message: "사원 상세 보기: \(employee.name)", details: "부서: \(employee.department), 벡터: \(employee.faceVectors.count)개")
                            selectedEmployee = employee
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                DebugLogger.shared.log(level: .warning, category: .general, message: "사원 삭제 요청: \(employee.name)")
                                employeeToDelete = employee
                                showDeleteConfirm = true
                            } label: {
                                Label("삭제", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                selectedEmployee = employee
                            } label: {
                                Label("편집", systemImage: "pencil")
                            }
                            .tint(.blue)
                        }
                }
            } header: {
                if let dept = selectedDepartment {
                    Text("\(dept) (\(filteredEmployees.count)명)")
                } else {
                    Text("전체 사원 (\(filteredEmployees.count)명)")
                }
            }
        }
    }

    // MARK: - 통계 행

    private var statisticsRow: some View {
        HStack(spacing: 20) {
            StatBox(
                title: "총 사원",
                value: "\(store.employees.count)",
                icon: "person.3.fill",
                color: .blue
            )

            StatBox(
                title: "부서 수",
                value: "\(store.sortedDepartments.count)",
                icon: "building.2.fill",
                color: .green
            )

            StatBox(
                title: "오늘 출근",
                value: "\(AttendanceStore.shared.todayCheckInCount)",
                icon: "checkmark.circle.fill",
                color: .orange
            )
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
    }

    // MARK: - 부서 필터 메뉴

    private var departmentFilterMenu: some View {
        Menu {
            Button {
                DebugLogger.shared.log(category: .general, message: "부서 필터 해제 → 전체 보기")
                selectedDepartment = nil
            } label: {
                HStack {
                    Text("전체 보기")
                    if selectedDepartment == nil {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            ForEach(store.sortedDepartments, id: \.self) { dept in
                Button {
                    DebugLogger.shared.log(category: .general, message: "부서 필터 적용: \(dept)", details: "\(store.departmentGroups[dept]?.count ?? 0)명")
                    selectedDepartment = dept
                } label: {
                    HStack {
                        Text(dept)
                        Spacer()
                        Text("\(store.departmentGroups[dept]?.count ?? 0)")
                            .foregroundStyle(.secondary)
                        if selectedDepartment == dept {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                if let dept = selectedDepartment {
                    Text(dept)
                        .font(.caption)
                }
            }
        }
    }
}

// MARK: - 사원 행

struct EmployeeRow: View {
    let employee: Employee

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.blue.gradient)
                    .frame(width: 48, height: 48)

                Text(employee.name.prefix(1))
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(employee.name)
                    .font(.headline)

                HStack(spacing: 8) {
                    Label(employee.department, systemImage: "building.2")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !employee.faceVectors.isEmpty {
                        Label("\(employee.faceVectors.count)개 벡터", systemImage: "faceid")
                            .font(.caption2)
                            .foregroundStyle(.blue)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                // 오늘 출근 여부
                if AttendanceStore.shared.hasCheckedInToday(employeeId: employee.id) {
                    Text("출근 완료")
                        .font(.caption2)
                        .fontWeight(.semibold)
                        .foregroundStyle(.green)
                }

                Text(employee.createdAt, format: .dateTime.month().day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - 사원 상세 뷰 (편집/삭제 지원)

struct EmployeeDetailView: View {
    let employee: Employee
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var attendanceStore = AttendanceStore.shared
    @ObservedObject private var employeeStore = EmployeeStore.shared

    @State private var isEditing = false
    @State private var editedName: String
    @State private var editedDepartment: String
    @State private var showDeleteConfirm = false
    @State private var showFaceReRegister = false
    @State private var newFaceVector: [Float]?
    @State private var newFaceVectors: [[Float]] = []
    @State private var faceReRegistered = false

    init(employee: Employee) {
        self.employee = employee
        _editedName = State(initialValue: employee.name)
        _editedDepartment = State(initialValue: employee.department)
    }

    private var employeeRecords: [AttendanceRecord] {
        attendanceStore.records(for: employee.id)
    }

    private var hasChanges: Bool {
        editedName != employee.name || editedDepartment != employee.department || faceReRegistered
    }

    var body: some View {
        NavigationStack {
            List {
                // 프로필 섹션
                Section {
                    if isEditing {
                        editableProfileSection
                    } else {
                        readOnlyProfileSection
                    }
                }

                // 등록 정보
                Section("등록 정보") {
                    LabeledContent("등록일") {
                        Text(employee.createdAt, format: .dateTime.year().month().day())
                    }
                    LabeledContent("얼굴 벡터") {
                        if faceReRegistered {
                            HStack(spacing: 4) {
                                Text("\(newFaceVectors.count)개 각도")
                                Text("(재등록됨)")
                                    .foregroundStyle(.green)
                                    .fontWeight(.semibold)
                            }
                        } else {
                            Text("\(employee.faceVectors.count)개 각도")
                        }
                    }
                    LabeledContent("벡터 차원") {
                        Text("\(faceReRegistered ? (newFaceVectors.first?.count ?? employee.faceVector.count) : employee.faceVector.count)차원")
                    }
                }

                // 얼굴 재등록
                if isEditing {
                    Section {
                        Button {
                            showFaceReRegister = true
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(faceReRegistered ? Color.green.opacity(0.12) : Color.blue.opacity(0.12))
                                        .frame(width: 44, height: 44)
                                    Image(systemName: faceReRegistered ? "checkmark.circle.fill" : "faceid")
                                        .foregroundStyle(faceReRegistered ? .green : .blue)
                                        .font(.title3)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(faceReRegistered ? "얼굴 재등록 완료" : "얼굴 재등록")
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(faceReRegistered ? "저장 시 새 얼굴 데이터가 적용됩니다" : "카메라로 얼굴을 다시 촬영합니다")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("얼굴 데이터")
                    }
                }

                // 출석 기록
                Section("최근 출석 기록") {
                    if employeeRecords.isEmpty {
                        Text("출석 기록이 없습니다")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(employeeRecords.prefix(10)) { record in
                            HStack {
                                Image(systemName: record.type.icon)
                                    .foregroundStyle(record.type.color)

                                Text(record.type.rawValue)
                                    .fontWeight(.medium)

                                Spacer()

                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(record.dateString)
                                        .font(.caption)
                                    Text(record.timeString)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }

                // 삭제 버튼
                Section {
                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        HStack {
                            Spacer()
                            Label("사원 삭제", systemImage: "trash")
                            Spacer()
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "사원 편집" : "사원 정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isEditing {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("취소") {
                            editedName = employee.name
                            editedDepartment = employee.department
                            faceReRegistered = false
                            newFaceVector = nil
                            newFaceVectors = []
                            isEditing = false
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("저장") {
                            saveChanges()
                        }
                        .fontWeight(.semibold)
                        .disabled(editedName.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  editedDepartment.trimmingCharacters(in: .whitespaces).isEmpty ||
                                  !hasChanges)
                    }
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("편집") {
                            DebugLogger.shared.log(category: .general, message: "사원 편집 모드 진입: \(employee.name)")
                            isEditing = true
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("닫기") { dismiss() }
                    }
                }
            }
            .fullScreenCover(isPresented: $showFaceReRegister) {
                FaceRegisterCameraView { vector, vectors in
                    newFaceVector = vector
                    newFaceVectors = vectors
                    faceReRegistered = true
                    DebugLogger.shared.log(category: .faceAuth, message: "얼굴 재등록 완료: \(employee.name)", details: "\(vectors.count)개 각도, \(vector.count)차원")
                }
            }
            .alert("사원 삭제", isPresented: $showDeleteConfirm) {
                Button("취소", role: .cancel) { }
                Button("삭제", role: .destructive) {
                    DebugLogger.shared.log(level: .warning, category: .database, message: "사원 삭제 확인: \(employee.name)", details: "부서: \(employee.department), 출석기록: \(employeeRecords.count)건")
                    employeeStore.delete(employee)
                    dismiss()
                }
            } message: {
                Text("\(employee.name)님을 삭제하시겠습니까?\n등록된 얼굴 정보와 출석 기록이 모두 삭제됩니다.")
            }
        }
    }

    // MARK: - 프로필 섹션

    private var readOnlyProfileSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.gradient)
                    .frame(width: 64, height: 64)
                Text(employee.name.prefix(1))
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(employee.name)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(employee.department)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var editableProfileSection: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.blue.gradient)
                    .frame(width: 64, height: 64)
                Text(editedName.isEmpty ? "?" : String(editedName.prefix(1)))
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("이름")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("이름을 입력하세요", text: $editedName)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("부서")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    TextField("부서를 입력하세요", text: $editedDepartment)
                        .font(.subheadline)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - 저장

    private func saveChanges() {
        var updated = employee
        updated.name = editedName.trimmingCharacters(in: .whitespaces)
        updated.department = editedDepartment.trimmingCharacters(in: .whitespaces)

        if faceReRegistered, let vector = newFaceVector {
            updated.faceVector = vector
            updated.faceVectors = newFaceVectors
        }

        employeeStore.update(updated)

        var details = "\(employee.name) → \(updated.name), \(employee.department) → \(updated.department)"
        if faceReRegistered {
            details += ", 얼굴 재등록: \(newFaceVectors.count)개 각도"
        }
        DebugLogger.shared.log(category: .database, message: "사원 정보 편집 완료", details: details)
        dismiss()
    }
}

// MARK: - 통계 박스

struct StatBox: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)

            Text(value)
                .font(.title2)
                .fontWeight(.bold)

            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.1))
        .cornerRadius(12)
    }
}

#Preview {
    EmployeeManagementView()
}
