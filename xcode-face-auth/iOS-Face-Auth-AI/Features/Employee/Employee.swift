//
//  Employee.swift
//  FaceAuthApp
//
//  Created by yon on 2026/02/01.
//

import Foundation
import GRDB

/// 사원 정보 모델
/// 사원 정보 모델
struct Employee: Sendable {
    var id: String
    var name: String
    var department: String
    var faceVector: [Float]        // 평균 얼굴 벡터 (AuraFace 512차원)
    var faceVectors: [[Float]]     // 각 각도별 벡터 (멀티앵글)
    var createdAt: Date

    init(id: String = UUID().uuidString,
         name: String,
         department: String,
         faceVector: [Float],
         faceVectors: [[Float]] = [],
         createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.department = department
        self.faceVector = faceVector
        self.faceVectors = faceVectors
        self.createdAt = createdAt
    }

    /// 멀티 벡터의 평균을 계산
    static func averageVector(from vectors: [[Float]]) -> [Float] {
        guard !vectors.isEmpty else { return [] }
        let dim = vectors[0].count
        var avg = [Float](repeating: 0, count: dim)
        for vec in vectors {
            for i in 0..<dim {
                avg[i] += vec[i]
            }
        }
        let count = Float(vectors.count)
        return avg.map { $0 / count }
    }

    // MARK: - 목업 데이터

    static let mockEmployees: [Employee] = [
        Employee(name: "김철수", department: "개발팀", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "이영희", department: "디자인팀", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "박민수", department: "기획팀", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "정수진", department: "마케팅팀", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "최지훈", department: "개발팀", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "강민지", department: "인사팀", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "윤서연", department: "개발팀", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "한동욱", department: "영업팀", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()])
    ]

    private static func generateMockVector() -> [Float] {
        (0..<512).map { _ in Float.random(in: -1...1) }
    }
}

extension Employee: Identifiable, Hashable {}

// MARK: - GRDB (FetchableRecord + PersistableRecord)

extension Employee: FetchableRecord, PersistableRecord {
    static let databaseTableName = "employee"

    /// DB 컬럼 이름
    enum Columns: String, ColumnExpression {
        case id, name, department, faceVectorData, faceVectorsData, createdAt
    }

    /// DB 행 → Employee 변환
    nonisolated init(row: Row) {
        id = row[Columns.id]
        name = row[Columns.name]
        department = row[Columns.department]
        createdAt = row[Columns.createdAt]

        // BLOB → [Float]
        let vectorData: Data = row[Columns.faceVectorData]
        faceVector = vectorData.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }

        // BLOB (JSON) → [[Float]]
        let vectorsData: Data = row[Columns.faceVectorsData]
        faceVectors = (try? JSONDecoder().decode([[Float]].self, from: vectorsData)) ?? []
    }

    /// Employee → DB 행 변환
    nonisolated func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.department] = department
        container[Columns.createdAt] = createdAt

        // [Float] → Data (BLOB)
        container[Columns.faceVectorData] = faceVector.withUnsafeBytes { Data($0) }

        // [[Float]] → Data (JSON BLOB)
        container[Columns.faceVectorsData] = (try? JSONEncoder().encode(faceVectors)) ?? Data()
    }
}

// MARK: - 얼굴 매칭 결과

struct FaceMatch: Identifiable {
    let id = UUID()
    let employee: Employee
    let confidence: Float

    var confidencePercent: Int {
        Int(confidence * 100)
    }
}
