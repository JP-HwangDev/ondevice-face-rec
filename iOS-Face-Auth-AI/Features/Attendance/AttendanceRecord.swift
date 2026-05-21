//
//  AttendanceRecord.swift
//  FaceAuthApp
//
//  출석 기록 모델 및 저장소 (GRDB/SQLite)
//

import Foundation
import SwiftUI
import Combine
import GRDB

// MARK: - 출석 기록 모델

struct AttendanceRecord: Sendable {
    var id: String
    var employeeId: String
    var employeeName: String
    var department: String
    var timestamp: Date
    var confidence: Float       // 인식 유사도 (0~1)
    var type: AttendanceType

    init(id: String = UUID().uuidString,
         employeeId: String,
         employeeName: String,
         department: String,
         timestamp: Date = Date(),
         confidence: Float,
         type: AttendanceType = .checkIn) {
        self.id = id
        self.employeeId = employeeId
        self.employeeName = employeeName
        self.department = department
        self.timestamp = timestamp
        self.confidence = confidence
        self.type = type
    }

    var confidencePercent: Int {
        Int(confidence * 100)
    }

    var timeString: String {
        timestamp.formatted(date: .omitted, time: .shortened)
    }

    var dateString: String {
        timestamp.formatted(date: .abbreviated, time: .omitted)
    }
}

extension AttendanceRecord: Identifiable {}

// MARK: - GRDB (FetchableRecord + PersistableRecord)

extension AttendanceRecord: FetchableRecord, PersistableRecord {
    static let databaseTableName = "attendanceLog"

    enum Columns: String, ColumnExpression {
        case id, employeeId, employeeName, department, timestamp, confidence, type
    }

    nonisolated init(row: Row) {
        id = row[Columns.id]
        employeeId = row[Columns.employeeId]
        employeeName = row[Columns.employeeName]
        department = row[Columns.department]
        timestamp = row[Columns.timestamp]
        confidence = row[Columns.confidence]
        let typeRaw: String = row[Columns.type]
        type = AttendanceType(rawValue: typeRaw) ?? .checkIn
    }

    nonisolated func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.employeeId] = employeeId
        container[Columns.employeeName] = employeeName
        container[Columns.department] = department
        container[Columns.timestamp] = timestamp
        container[Columns.confidence] = confidence
        container[Columns.type] = type.rawValue
    }
}

// MARK: - 출석 유형

enum AttendanceType: String, Codable, CaseIterable, Sendable {
    case checkIn = "출근"
    case checkOut = "퇴근"

    var icon: String {
        switch self {
        case .checkIn: return "arrow.right.to.line"
        case .checkOut: return "arrow.left.to.line"
        }
    }

    var color: Color {
        switch self {
        case .checkIn: return .green
        case .checkOut: return .orange
        }
    }
}

// MARK: - 출석 저장소 (GRDB)

@MainActor
class AttendanceStore: ObservableObject {
    static let shared = AttendanceStore()

    @Published private(set) var records: [AttendanceRecord] = []

    private var dbQueue: DatabaseQueue { DatabaseManager.shared.dbQueue }

    private init() {
        load()
    }

    // MARK: - 출석 기록 추가

    func record(employee: Employee, confidence: Float, type: AttendanceType = .checkIn) {
        let record = AttendanceRecord(
            employeeId: employee.id,
            employeeName: employee.name,
            department: employee.department,
            confidence: confidence,
            type: type
        )

        do {
            try dbQueue.write { db in
                try record.insert(db)
            }
            records.insert(record, at: 0)
            DebugLogger.shared.log(
                category: .database,
                message: "\(type.rawValue) 기록 저장: \(employee.name) (\(employee.department))",
                details: "유사도: \(record.confidencePercent)%, 시각: \(record.timeString)"
            )
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "출석 기록 저장 실패", details: error.localizedDescription)
        }
    }

    // MARK: - 조회

    /// 오늘 출석 기록
    var todayRecords: [AttendanceRecord] {
        let calendar = Calendar.current
        return records.filter { calendar.isDateInToday($0.timestamp) }
    }

    /// 오늘 출근한 사원 수
    var todayCheckInCount: Int {
        let uniqueEmployees = Set(todayRecords.filter { $0.type == .checkIn }.map { $0.employeeId })
        return uniqueEmployees.count
    }

    /// 특정 사원의 출석 기록
    func records(for employeeId: String) -> [AttendanceRecord] {
        records.filter { $0.employeeId == employeeId }
    }

    /// 특정 사원이 오늘 이미 출근했는지 확인
    func hasCheckedInToday(employeeId: String) -> Bool {
        let calendar = Calendar.current
        return records.contains {
            $0.employeeId == employeeId &&
            $0.type == .checkIn &&
            calendar.isDateInToday($0.timestamp)
        }
    }

    /// 날짜별 그룹
    var recordsByDate: [String: [AttendanceRecord]] {
        Dictionary(grouping: records) { record in
            record.timestamp.formatted(date: .abbreviated, time: .omitted)
        }
    }

    /// 정렬된 날짜 키
    var sortedDates: [String] {
        recordsByDate.keys.sorted { a, b in
            guard let dateA = records.first(where: { $0.dateString == a })?.timestamp,
                  let dateB = records.first(where: { $0.dateString == b })?.timestamp else {
                return a > b
            }
            return dateA > dateB
        }
    }

    // MARK: - 삭제

    func deleteAll() {
        let count = records.count
        do {
            try dbQueue.write { db in
                try AttendanceRecord.deleteAll(db)
            }
            records.removeAll()
            DebugLogger.shared.log(level: .warning, category: .database, message: "출석 기록 전체 삭제: \(count)건")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "출석 기록 전체 삭제 실패", details: error.localizedDescription)
        }
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { records[$0] }
        do {
            try dbQueue.write { db in
                for record in toDelete {
                    try record.delete(db)
                }
            }
            records.remove(atOffsets: offsets)
            let names = toDelete.map { $0.employeeName }.joined(separator: ", ")
            DebugLogger.shared.log(level: .warning, category: .database, message: "출석 기록 삭제: \(names)")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "출석 기록 삭제 실패", details: error.localizedDescription)
        }
    }

    // MARK: - DB 로드

    private func load() {
        guard DatabaseManager.shared.dbQueue != nil else { return }
        do {
            records = try dbQueue.read { db in
                try AttendanceRecord
                    .order(Column("timestamp").desc)
                    .fetchAll(db)
            }
            DebugLogger.shared.log(category: .database, message: "출석 기록 로드 완료: \(records.count)건, 오늘: \(todayRecords.count)건")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "출석 기록 로드 실패", details: error.localizedDescription)
        }
    }

    /// 외부에서 DB 변경 후 리로드
    func reload() {
        load()
    }
}
