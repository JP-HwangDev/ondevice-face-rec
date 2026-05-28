//
//  DatabaseManager.swift
//  FaceAuthApp
//
//  GRDB database setup and migrations.
//

import Foundation
import GRDB

final class DatabaseManager {
    static let shared = DatabaseManager()

    private(set) var dbQueue: DatabaseQueue!

    private init() {}

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

    private func runMigrations() throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_createTables") { db in
            try db.create(table: "employee", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull()
                t.column("department", .text).notNull()
                t.column("faceVectorData", .blob).notNull()
                t.column("faceVectorsData", .blob).notNull()
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "attendanceLog", ifNotExists: true) { t in
                t.column("id", .text).primaryKey()
                t.column("employeeId", .text).notNull()
                    .references("employee", onDelete: .cascade)
                t.column("employeeName", .text).notNull()
                t.column("department", .text).notNull()
                t.column("timestamp", .datetime).notNull()
                t.column("confidence", .double).notNull()
                t.column("type", .text).notNull()
            }

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

        migrator.registerMigration("v2_addEmbeddingModelToEmployee") { db in
            try db.alter(table: "employee") { t in
                t.add(column: "embeddingModel", .text).notNull().defaults(to: "Legacy")
            }
        }

        try migrator.migrate(dbQueue)
    }
}
