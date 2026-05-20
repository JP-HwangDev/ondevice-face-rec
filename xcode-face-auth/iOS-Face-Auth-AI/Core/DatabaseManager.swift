//
//  DatabaseManager.swift
//  FaceAuthApp
//
//  GRDB.swift 데이터베이스 초기화 및 마이그레이션
//

import Foundation
import GRDB

class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbQueue: DatabaseQueue!

    private init() {}

    /// 앱 시작 시 호출 — DB 파일 생성 + 테이블 마이그레이션
    func setup() throws {
        let fileManager = FileManager.default
        let appSupportURL = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dbURL = appSupportURL.appendingPathComponent("faceauth.sqlite")

        var config = Configuration()
        #if DEBUG
        config.prepareDatabase { db in
            db.trace { print("[SQL] \($0)") }
        }
        #endif

        dbQueue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try runMigrations()

        DebugLogger.shared.log(category: .database, message: "DB 파일 경로: \(dbURL.path)")
    }

    // MARK: - 마이그레이션

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        // v1: 초기 테이블 생성
        migrator.registerMigration("v1_createTables") { db in
            // 사원 테이블
            try db.create(table: "employee", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("department", .text).notNull()
                t.column("faceVectorData", .blob).notNull()       // [Float] → Data
                t.column("faceVectorsData", .blob).notNull()       // [[Float]] → Data (JSON)
                t.column("createdAt", .datetime).notNull()
            }

            // 출석 기록 테이블
            try db.create(table: "attendanceLog", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("employeeId", .text).notNull()
                    .references("employee", onDelete: .cascade)
                t.column("employeeName", .text).notNull()
                t.column("department", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("confidence", .double).notNull()
                t.column("type", .text).notNull()                  // "출근" / "퇴근"
            }

            // 인덱스
            try db.create(
                index: "idx_attendanceLog_employeeId",
                on: "attendanceLog",
                columns: ["employeeId"],
                ifNotExists: true
            )
            try db.create(
                index: "idx_attendanceLog_timestamp",
                on: "attendanceLog",
                columns: ["timestamp"],
                ifNotExists: true
            )
        }

        try migrator.migrate(dbQueue)
    }


}
