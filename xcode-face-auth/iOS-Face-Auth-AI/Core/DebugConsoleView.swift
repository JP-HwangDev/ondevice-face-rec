//
//  DebugConsoleView.swift
//  iOS-Face-Auth-AI
//
//  디버그 콘솔 UI — 로그 뷰어 + DB 뷰어
//

import SwiftUI
import GRDB

struct DebugConsoleView: View {
    @ObservedObject private var logger = DebugLogger.shared
    @State private var selectedTab: DebugTab = .logs

    enum DebugTab: String, CaseIterable {
        case logs = "Logs"
        case database = "Database"
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Tab picker
                Picker("", selection: $selectedTab) {
                    ForEach(DebugTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.top, 8)

                switch selectedTab {
                case .logs:
                    LogsTabView()
                case .database:
                    DatabaseTabView()
                }
            }
            .navigationTitle("Debug Console")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Logs Tab

private struct LogsTabView: View {
    @ObservedObject private var logger = DebugLogger.shared
    @State private var enabledCategories: Set<LogCategory> = Set(LogCategory.allCases)
    @State private var expandedLogId: UUID?

    private var filteredLogs: [LogEntry] {
        logger.logs.filter { enabledCategories.contains($0.category) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Category filters
            categoryFilterBar

            Divider()

            if filteredLogs.isEmpty {
                ContentUnavailableView(
                    "로그 없음",
                    systemImage: "doc.text",
                    description: Text("아직 기록된 로그가 없습니다")
                )
            } else {
                ScrollViewReader { proxy in
                    List(filteredLogs) { entry in
                        LogRowView(
                            entry: entry,
                            isExpanded: expandedLogId == entry.id,
                            onTap: {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    expandedLogId = expandedLogId == entry.id ? nil : entry.id
                                }
                            }
                        )
                        .id(entry.id)
                        .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
                    }
                    .listStyle(.plain)
                    .onChange(of: logger.logs.count) {
                        if let last = filteredLogs.last {
                            withAnimation {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    copyLogs()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .disabled(filteredLogs.isEmpty)

                Button(role: .destructive) {
                    logger.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(logger.logs.isEmpty)
            }
        }
    }

    // MARK: - Category Filter Bar

    private var categoryFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(LogCategory.allCases, id: \.self) { category in
                    let isEnabled = enabledCategories.contains(category)
                    Button {
                        if isEnabled {
                            enabledCategories.remove(category)
                        } else {
                            enabledCategories.insert(category)
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: category.icon)
                                .font(.caption2)
                            Text(category.rawValue)
                                .font(.caption)
                                .fontWeight(.medium)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(isEnabled ? Color.accentColor.opacity(0.15) : Color(.tertiarySystemFill))
                        .foregroundStyle(isEnabled ? Color.accentColor : .secondary)
                        .cornerRadius(8)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
    }

    // MARK: - Copy Logs

    private func copyLogs() {
        let text = filteredLogs.map { entry in
            var line = "[\(entry.formattedTimestamp)][\(entry.level.rawValue)][\(entry.category.rawValue)] \(entry.message)"
            if let details = entry.details {
                line += "\n  ↳ \(details)"
            }
            return line
        }.joined(separator: "\n")

        UIPasteboard.general.string = text
    }
}

// MARK: - Log Row

private struct LogRowView: View {
    let entry: LogEntry
    let isExpanded: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: entry.level.icon)
                        .font(.caption)
                        .foregroundStyle(entry.level.color)

                    Text(entry.formattedTimestamp)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()

                    Text(entry.category.rawValue)
                        .font(.caption2)
                        .fontWeight(.medium)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color(.tertiarySystemFill))
                        .cornerRadius(4)

                    Spacer()
                }

                Text(entry.message)
                    .font(.subheadline)
                    .foregroundStyle(entry.level == .error ? .red : .primary)
                    .lineLimit(isExpanded ? nil : 2)

                if isExpanded, let details = entry.details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(.tertiarySystemBackground))
                        .cornerRadius(6)

                    Button {
                        UIPasteboard.general.string = details
                    } label: {
                        Label("Copy Details", systemImage: "doc.on.doc")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Database Tab

private struct DatabaseTabView: View {
    enum DBTable: String, CaseIterable {
        case employees = "employee"
        case attendanceLogs = "attendanceLog"

        var displayName: String {
            switch self {
            case .employees: return "사원 (employee)"
            case .attendanceLogs: return "출석 기록 (attendanceLog)"
            }
        }
    }

    @State private var selectedTable: DBTable = .employees
    @State private var rows: [[String: String]] = []
    @State private var columns: [String] = []
    @State private var isLoading = false
    @State private var showResetConfirmation = false
    @State private var rowCount = 0

    var body: some View {
        VStack(spacing: 0) {
            // Table picker
            Picker("Table", selection: $selectedTable) {
                ForEach(DBTable.allCases, id: \.self) { table in
                    Text(table.displayName).tag(table)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Row count
            HStack {
                Text("\(rowCount) rows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 4)

            Divider()

            if isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if rows.isEmpty {
                ContentUnavailableView(
                    "데이터 없음",
                    systemImage: "tablecells",
                    description: Text("이 테이블에 데이터가 없습니다")
                )
            } else {
                tableContent
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    fetchData()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }

                Button(role: .destructive) {
                    showResetConfirmation = true
                } label: {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(.red)
                }
            }
        }
        .confirmationDialog(
            "DB 초기화",
            isPresented: $showResetConfirmation,
            titleVisibility: .visible
        ) {
            Button("모든 데이터 삭제", role: .destructive) {
                resetDatabase()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text("모든 테이블의 데이터가 삭제됩니다. 이 작업은 되돌릴 수 없습니다.")
        }
        .onAppear { fetchData() }
        .onChange(of: selectedTable) { fetchData() }
    }

    // MARK: - Table Content

    private var tableContent: some View {
        ScrollView(.horizontal) {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    // Header row
                    HStack(spacing: 0) {
                        ForEach(columns, id: \.self) { col in
                            Text(col)
                                .font(.caption)
                                .fontWeight(.bold)
                                .frame(width: columnWidth(for: col), alignment: .leading)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                    .background(Color(.secondarySystemBackground))

                    Divider()

                    // Data rows
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(columns, id: \.self) { col in
                                Text(row[col] ?? "NULL")
                                    .font(.caption2)
                                    .foregroundStyle(row[col] == nil ? .secondary : .primary)
                                    .lineLimit(1)
                                    .frame(width: columnWidth(for: col), alignment: .leading)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 5)
                            }
                        }
                        .background(index % 2 == 0 ? Color.clear : Color(.tertiarySystemFill).opacity(0.5))
                    }
                }
            }
        }
    }

    // MARK: - Column Width

    private func columnWidth(for column: String) -> CGFloat {
        switch column {
        case "id":
            return 100
        case "faceVectorData", "faceVectorsData":
            return 160
        case "name", "employeeName", "department", "type":
            return 100
        case "timestamp", "createdAt":
            return 150
        case "confidence":
            return 80
        default:
            return 120
        }
    }

    // MARK: - Fetch Data

    private func fetchData() {
        isLoading = true
        let tableName = selectedTable.rawValue

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let result: (columns: [String], rows: [[String: String]], count: Int) = try DatabaseManager.shared.dbQueue.read { db in
                    let tableColumns = try db.columns(in: tableName)
                    let colNames = tableColumns.map { $0.name }

                    let dbRows = try Row.fetchAll(db, sql: "SELECT * FROM \(tableName) ORDER BY rowid DESC LIMIT 200")
                    let mapped: [[String: String]] = dbRows.map { row in
                        var dict: [String: String] = [:]
                        for col in colNames {
                            if let value = row[col] as DatabaseValue? {
                                switch value.storage {
                                case .null:
                                    dict[col] = nil
                                case .int64(let v):
                                    dict[col] = String(v)
                                case .double(let v):
                                    dict[col] = String(format: "%.4f", v)
                                case .string(let v):
                                    dict[col] = v
                                case .blob(let data):
                                    dict[col] = "<\(data.count) bytes>"
                                }
                            }
                        }
                        return dict
                    }

                    let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(tableName)") ?? 0
                    return (colNames, mapped, count)
                }

                DispatchQueue.main.async {
                    self.columns = result.columns
                    self.rows = result.rows
                    self.rowCount = result.count
                    self.isLoading = false

                    DebugLogger.shared.log(
                        category: .database,
                        message: "Fetched \(result.count) rows from \(tableName)"
                    )
                }
            } catch {
                DispatchQueue.main.async {
                    self.columns = []
                    self.rows = []
                    self.rowCount = 0
                    self.isLoading = false

                    DebugLogger.shared.log(
                        level: .error,
                        category: .database,
                        message: "Failed to fetch \(tableName)",
                        details: error.localizedDescription
                    )
                }
            }
        }
    }

    // MARK: - Reset Database

    private func resetDatabase() {
        do {
            try DatabaseManager.shared.dbQueue.write { db in
                try db.execute(sql: "DELETE FROM attendanceLog")
                try db.execute(sql: "DELETE FROM employee")
            }

            // Refresh stores
            EmployeeStore.shared.reload()
            AttendanceStore.shared.reload()

            fetchData()

            DebugLogger.shared.log(
                level: .warning,
                category: .database,
                message: "Database reset — all data deleted"
            )
        } catch {
            DebugLogger.shared.log(
                level: .error,
                category: .database,
                message: "Database reset failed",
                details: error.localizedDescription
            )
        }
    }
}

#Preview {
    DebugConsoleView()
}
