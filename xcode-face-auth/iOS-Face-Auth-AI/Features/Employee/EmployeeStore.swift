//
//  EmployeeStore.swift
//  FaceAuthApp
//
//  Created by yon on 2026/02/01.
//

import Foundation
import Combine
import SwiftUI
import GRDB

/// 앱 전역 사원 데이터 저장소 (GRDB/SQLite 영속 저장)
@MainActor
class EmployeeStore: ObservableObject {
    static let shared = EmployeeStore()

    @Published private(set) var employees: [Employee] = []

    private var dbQueue: DatabaseQueue { DatabaseManager.shared.dbQueue }

    private init() {
        load()
    }

    // MARK: - CRUD

    func add(_ employee: Employee) {
        do {
            try dbQueue.write { db in
                try employee.insert(db)
            }
            employees.append(employee)
            DebugLogger.shared.log(category: .database, message: "사원 추가: \(employee.name) (\(employee.department))", details: "벡터 수: \(employee.faceVectors.count), 차원: \(employee.faceVector.count)")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 추가 실패: \(employee.name)", details: error.localizedDescription)
        }
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { employees[$0] }
        do {
            try dbQueue.write { db in
                for emp in toDelete {
                    try emp.delete(db)
                }
            }
            employees.remove(atOffsets: offsets)
            let names = toDelete.map { $0.name }.joined(separator: ", ")
            DebugLogger.shared.log(level: .warning, category: .database, message: "사원 삭제: \(names)")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 삭제 실패", details: error.localizedDescription)
        }
    }

    func delete(_ employee: Employee) {
        do {
            try dbQueue.write { db in
                try employee.delete(db)
            }
            employees.removeAll { $0.id == employee.id }
            DebugLogger.shared.log(level: .warning, category: .database, message: "사원 삭제: \(employee.name) (\(employee.department))")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 삭제 실패: \(employee.name)", details: error.localizedDescription)
        }
    }

    func update(_ employee: Employee) {
        do {
            try dbQueue.write { db in
                try employee.update(db)
            }
            if let index = employees.firstIndex(where: { $0.id == employee.id }) {
                employees[index] = employee
            }
            DebugLogger.shared.log(category: .database, message: "사원 수정: \(employee.name) (\(employee.department))")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 수정 실패: \(employee.name)", details: error.localizedDescription)
        }
    }

    func deleteAll() {
        do {
            let count = employees.count
            try dbQueue.write { db in
                try Employee.deleteAll(db)
            }
            employees.removeAll()
            DebugLogger.shared.log(level: .warning, category: .database, message: "사원 전체 삭제: \(count)명")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 전체 삭제 실패", details: error.localizedDescription)
        }
    }

    // MARK: - 부서별 그룹

    var departmentGroups: [String: [Employee]] {
        Dictionary(grouping: employees, by: { $0.department })
    }

    var sortedDepartments: [String] {
        departmentGroups.keys.sorted()
    }

    // MARK: - DB 로드

    private func load() {
        guard DatabaseManager.shared.dbQueue != nil else { return }
        do {
            employees = try dbQueue.read { db in
                try Employee.fetchAll(db)
            }

            // 첫 실행이면 목업 데이터 삽입
            if employees.isEmpty {
                try dbQueue.write { db in
                    for emp in Employee.mockEmployees {
                        try emp.insert(db)
                    }
                }
                employees = Employee.mockEmployees
                DebugLogger.shared.log(category: .database, message: "첫 실행 — 목업 사원 \(employees.count)명 삽입")
            }

            DebugLogger.shared.log(category: .database, message: "사원 DB 로드 완료: \(employees.count)명")
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 DB 로드 실패", details: error.localizedDescription)
        }
    }

    /// 외부에서 DB 변경 후 리로드
    func reload() {
        load()
    }
}
