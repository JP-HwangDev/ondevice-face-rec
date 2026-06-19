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

/// App-wide employee store backed by GRDB/SQLite.
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
            DebugLogger.shared.log(
                category: .database,
                message: "사원 추가: \(employee.name) (\(employee.department))",
                details: "모델: \(employee.embeddingModel), 벡터 수: \(employee.faceVectors.count), 차원: \(employee.faceVector.count)"
            )
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 추가 실패: \(employee.name)", details: error.localizedDescription)
        }
    }

    func delete(at offsets: IndexSet) {
        let toDelete = offsets.map { employees[$0] }
        do {
            try dbQueue.write { db in
                for employee in toDelete {
                    try employee.delete(db)
                }
            }
            employees.remove(atOffsets: offsets)
            let names = toDelete.map(\.name).joined(separator: ", ")
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
            DebugLogger.shared.log(
                category: .database,
                message: "사원 수정: \(employee.name) (\(employee.department))",
                details: "모델: \(employee.embeddingModel), 차원: \(employee.embeddingDimension)"
            )
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 수정 실패: \(employee.name)", details: error.localizedDescription)
        }
    }

    func appendEmbedding(_ vector: [Float], toEmployeeId id: String, cap: Int = 100) {
        guard !vector.isEmpty,
              let index = employees.firstIndex(where: { $0.id == id }),
              employees[index].faceVector.count == vector.count else { return }

        var employee = employees[index]
        var updated = employee.faceVectors
        updated.append(vector)
        if updated.count > cap {
            updated.removeFirst(updated.count - cap)
        }
        employee.faceVectors = updated
        employee.faceVector = Employee.averageVector(from: updated)

        do {
            try dbQueue.write { db in
                try employee.update(db)
            }
            employees[index] = employee
            DebugLogger.shared.log(
                category: .faceAuth,
                message: "임베딩 갱신: \(employee.name)",
                details: "갤러리 \(updated.count)/\(cap)개"
            )
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "임베딩 갱신 실패: \(employee.name)", details: error.localizedDescription)
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

    // MARK: - Grouping

    var departmentGroups: [String: [Employee]] {
        Dictionary(grouping: employees, by: \.department)
    }

    var sortedDepartments: [String] {
        departmentGroups.keys.sorted()
    }

    // MARK: - DB Loading

    private func load() {
        guard DatabaseManager.shared.dbQueue != nil else { return }

        do {
            employees = try dbQueue.read { db in
                try Employee.fetchAll(db)
            }

            if employees.isEmpty {
                DebugLogger.shared.log(
                    level: .warning,
                    category: .database,
                    message: "사원 DB가 비어 있음",
                    details: "실사용 전 사원 얼굴 등록이 필요합니다."
                )
            } else {
                DebugLogger.shared.log(category: .database, message: "사원 DB 로드 완료: \(employees.count)명")
            }
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "사원 DB 로드 실패", details: error.localizedDescription)
        }
    }

    func reload() {
        load()
    }
}
