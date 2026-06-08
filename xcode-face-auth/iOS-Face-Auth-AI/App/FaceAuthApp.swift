//
//  FaceAuthApp.swift
//  FaceAuthApp
//
//  Created by yon on 2026/01/24.
//

import SwiftUI

@main
struct FaceAuthApp: App {
    private let defaultSimilarityThreshold = 0.4

    init() {
        UserDefaults.standard.register(defaults: [
            "similarity_threshold": defaultSimilarityThreshold
        ])

        do {
            try DatabaseManager.shared.setup()
            DebugLogger.shared.log(category: .database, message: "GRDB 데이터베이스 초기화 완료")
            DebugLogger.shared.log(
                category: .general,
                message: "앱 시작",
                details: "사원 수: \(EmployeeStore.shared.employees.count), 출석 기록: \(AttendanceStore.shared.records.count)건"
            )
        } catch {
            DebugLogger.shared.log(level: .error, category: .database, message: "데이터베이스 초기화 실패", details: error.localizedDescription)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
