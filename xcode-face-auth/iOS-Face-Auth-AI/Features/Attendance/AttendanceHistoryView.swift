//
//  AttendanceHistoryView.swift
//  FaceAuthApp
//
//  출석 이력 조회 화면
//

import SwiftUI

struct AttendanceHistoryView: View {
    @ObservedObject private var store = AttendanceStore.shared
    @ObservedObject private var employeeStore = EmployeeStore.shared
    @State private var selectedFilter: AttendanceFilter = .all
    @State private var searchText = ""

    enum AttendanceFilter: String, CaseIterable {
        case all = "전체"
        case today = "오늘"
        case checkIn = "출근"
        case checkOut = "퇴근"
    }

    private var filteredRecords: [AttendanceRecord] {
        var records = store.records

        switch selectedFilter {
        case .all:
            break
        case .today:
            let calendar = Calendar.current
            records = records.filter { calendar.isDateInToday($0.timestamp) }
        case .checkIn:
            records = records.filter { $0.type == .checkIn }
        case .checkOut:
            records = records.filter { $0.type == .checkOut }
        }

        if !searchText.isEmpty {
            records = records.filter {
                $0.employeeName.localizedCaseInsensitiveContains(searchText) ||
                $0.department.localizedCaseInsensitiveContains(searchText)
            }
        }

        return records
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    emptyStateView
                } else {
                    recordsListView
                }
            }
            .navigationTitle("출석 이력")
            .searchable(text: $searchText, prompt: "이름 또는 부서 검색")
        }
    }

    // MARK: - 빈 상태

    private var emptyStateView: some View {
        ContentUnavailableView {
            Label("출석 기록 없음", systemImage: "clock.badge.questionmark")
        } description: {
            Text("얼굴 인식 출석 체크를 시작하면\n이곳에서 기록을 확인할 수 있습니다.")
        }
    }

    // MARK: - 기록 목록

    private var recordsListView: some View {
        List {
            // 오늘 통계 요약
            Section {
                todaySummaryRow
            }

            // 필터
            Section {
                Picker("필터", selection: $selectedFilter) {
                    ForEach(AttendanceFilter.allCases, id: \.self) { filter in
                        Text(filter.rawValue).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            // 기록 목록
            if filteredRecords.isEmpty {
                Section {
                    Text("해당 조건의 기록이 없습니다")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            } else {
                // 날짜별 그룹
                ForEach(groupedByDate.keys.sorted(by: >), id: \.self) { dateKey in
                    Section(dateKey) {
                        ForEach(groupedByDate[dateKey] ?? []) { record in
                            AttendanceRecordRow(record: record)
                        }
                    }
                }
            }
        }
    }

    /// 날짜별 그룹핑
    private var groupedByDate: [String: [AttendanceRecord]] {
        Dictionary(grouping: filteredRecords) { record in
            record.dateString
        }
    }

    // MARK: - 오늘 통계

    private var todaySummaryRow: some View {
        HStack(spacing: 16) {
            SummaryCard(
                title: "오늘 출근",
                value: "\(store.todayCheckInCount)",
                total: "\(employeeStore.employees.count)명 중",
                icon: "person.fill.checkmark",
                color: .green
            )

            SummaryCard(
                title: "오늘 기록",
                value: "\(store.todayRecords.count)",
                total: "건",
                icon: "list.clipboard.fill",
                color: .blue
            )

            SummaryCard(
                title: "총 기록",
                value: "\(store.records.count)",
                total: "건",
                icon: "chart.bar.fill",
                color: .purple
            )
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
        .listRowBackground(Color.clear)
    }
}

// MARK: - 출석 기록 행

struct AttendanceRecordRow: View {
    let record: AttendanceRecord

    var body: some View {
        HStack(spacing: 14) {
            // 타입 아이콘
            ZStack {
                Circle()
                    .fill(record.type.color.opacity(0.15))
                    .frame(width: 44, height: 44)
                Image(systemName: record.type.icon)
                    .font(.body)
                    .foregroundStyle(record.type.color)
            }

            // 사원 정보
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.employeeName)
                        .font(.headline)
                    Text(record.type.rawValue)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(record.type.color)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(record.type.color.opacity(0.12))
                        .cornerRadius(4)
                }

                Text(record.department)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            // 시간 및 유사도
            VStack(alignment: .trailing, spacing: 4) {
                Text(record.timeString)
                    .font(.subheadline)
                    .fontWeight(.medium)

                HStack(spacing: 2) {
                    Image(systemName: "faceid")
                        .font(.caption2)
                    Text("\(record.confidencePercent)%")
                        .font(.caption)
                }
                .foregroundStyle(confidenceColor)
            }
        }
        .padding(.vertical, 2)
    }

    private var confidenceColor: Color {
        switch record.confidence {
        case 0.7...:
            return .green
        case 0.5..<0.7:
            return .orange
        default:
            return .red
        }
    }
}

// MARK: - 요약 카드

struct SummaryCard: View {
    let title: String
    let value: String
    let total: String
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

            Text(total)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(color.opacity(0.08))
        .cornerRadius(12)
    }
}

#Preview {
    AttendanceHistoryView()
}
