//
//  Employee.swift
//  FaceAuthApp
//
//  Created by yon on 2026/02/01.
//

import Foundation
import GRDB

struct Employee: Sendable {
    var id: String
    var name: String
    var department: String
    var embeddingModel: String
    var faceVector: [Float]
    var faceVectors: [[Float]]
    var createdAt: Date

    init(
        id: String = UUID().uuidString,
        name: String,
        department: String,
        embeddingModel: String = "Unknown",
        faceVector: [Float],
        faceVectors: [[Float]] = [],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.department = department
        self.embeddingModel = embeddingModel
        self.faceVector = faceVector
        self.faceVectors = faceVectors
        self.createdAt = createdAt
    }

    var embeddingDimension: Int {
        faceVector.count
    }

    func isCompatible(withModel modelName: String?, dimension: Int) -> Bool {
        guard let modelName else { return false }
        guard embeddingModel == modelName, faceVector.count == dimension else { return false }
        return faceVectors.allSatisfy { $0.count == dimension }
    }

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
        avg = avg.map { $0 / count }

        let sumOfSquares = avg.reduce(Float(0)) { $0 + $1 * $1 }
        let norm = sqrt(sumOfSquares)
        guard norm > 0 else { return avg }
        return avg.map { $0 / norm }
    }

    static let mockEmployees: [Employee] = [
        Employee(name: "김철수", department: "개발팀", embeddingModel: "Mock", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "이영희", department: "디자인팀", embeddingModel: "Mock", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "박민수", department: "기획팀", embeddingModel: "Mock", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "정수진", department: "마케팅팀", embeddingModel: "Mock", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "최지훈", department: "개발팀", embeddingModel: "Mock", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "강민지", department: "인사팀", embeddingModel: "Mock", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "윤서연", department: "개발팀", embeddingModel: "Mock", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()]),
        Employee(name: "한동욱", department: "영업팀", embeddingModel: "Mock", faceVector: generateMockVector(), faceVectors: [generateMockVector(), generateMockVector()])
    ]

    private static func generateMockVector() -> [Float] {
        (0..<512).map { _ in Float.random(in: -1...1) }
    }
}

extension Employee: Identifiable, Hashable {}

extension Employee: FetchableRecord, PersistableRecord {
    static let databaseTableName = "employee"

    enum Columns: String, ColumnExpression {
        case id, name, department, embeddingModel, faceVectorData, faceVectorsData, createdAt
    }

    nonisolated init(row: Row) {
        id = row[Columns.id]
        name = row[Columns.name]
        department = row[Columns.department]
        embeddingModel = row[Columns.embeddingModel]
        createdAt = row[Columns.createdAt]

        let vectorData: Data = row[Columns.faceVectorData]
        faceVector = vectorData.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }

        let vectorsData: Data = row[Columns.faceVectorsData]
        faceVectors = (try? JSONDecoder().decode([[Float]].self, from: vectorsData)) ?? []
    }

    nonisolated func encode(to container: inout PersistenceContainer) {
        container[Columns.id] = id
        container[Columns.name] = name
        container[Columns.department] = department
        container[Columns.embeddingModel] = embeddingModel
        container[Columns.createdAt] = createdAt
        container[Columns.faceVectorData] = faceVector.withUnsafeBytes { Data($0) }
        container[Columns.faceVectorsData] = (try? JSONEncoder().encode(faceVectors)) ?? Data()
    }
}

struct FaceMatch: Identifiable {
    let id = UUID()
    let employee: Employee
    let confidence: Float

    var confidencePercent: Int {
        Int(confidence * 100)
    }
}
