import Foundation
import Combine
import SwiftUI
import SQLite3

enum FaceUserType: String, Codable {
    case employee = "EMPLOYEE"
    case visitor = "VISITOR"

    var label: String {
        switch self {
        case .employee: return "社員"
        case .visitor: return "訪問者"
        }
    }
}

struct FaceUser: Identifiable, Codable {
    let id: String
    let name: String
    let department: String
    var faceSignatures: [[Float]]
    var registeredAt: Date
    var lastSeenAt: Date?
    var userType: FaceUserType
    var visitPurpose: String?

    init(id: String, name: String, department: String, faceSignatures: [[Float]], registeredAt: Date = Date(), lastSeenAt: Date? = nil, userType: FaceUserType = .employee, visitPurpose: String? = nil) {
        self.id = id
        self.name = name
        self.department = department
        self.faceSignatures = faceSignatures
        self.registeredAt = registeredAt
        self.lastSeenAt = lastSeenAt
        self.userType = userType
        self.visitPurpose = visitPurpose
    }

    var isVisitor: Bool { userType == .visitor }
    var displaySubtitle: String { isVisitor ? department : (department.isEmpty ? "本社" : department) }

    var initials: String {
        let components = name.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1)) + String(components[1].prefix(1))
        }
        return String(name.prefix(2))
    }
}

struct AttendanceRecord: Identifiable, Codable {
    let id: UUID
    let userName: String
    let timestamp: Date
    let type: String // "checkIn" or "checkOut"

    var isCheckIn: Bool { type == "checkIn" }
}

class FaceVectorStore: ObservableObject {
    @Published var users: [FaceUser] = []
    @Published var attendanceLogs: [AttendanceRecord] = []
    @Published var todayAttendance: [String: AttendanceEntry] = [:] // userName -> AttendanceEntry
    @Published var weeklyStats: [DayStat] = []
    @Published var consentLogs: [ConsentRecord] = []

    struct DayStat: Identifiable {
        let id = UUID()
        let day: String
        let count: Int
    }

    struct ConsentRecord: Identifiable, Codable {
        let id: String
        let userName: String
        let consentVersion: String
        let timestamp: Date
    }

    private var db: OpaquePointer?
    private let dbPath: String = {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("face_db.sqlite")
        return url.path
    }()

    private let dbQueue = DispatchQueue(label: "db.queue", qos: .userInitiated)

    init() {
        openDatabase()
        createTables()
        migrateTables()
        loadUsers()
        loadLogs()
        loadTodayAttendance()
        loadConsentLogs()
    }

    deinit {
        if db != nil {
            sqlite3_close(db)
        }
    }

    private func openDatabase() {
        if sqlite3_open(dbPath, &db) != SQLITE_OK {
            print("Error opening database")
        }
        // Enable WAL mode for better concurrent performance
        execute(sql: "PRAGMA journal_mode=WAL;")
        execute(sql: "PRAGMA synchronous=NORMAL;")
        execute(sql: "PRAGMA cache_size=10000;")
    }

    private func createTables() {
        let createUsersTable = """
        CREATE TABLE IF NOT EXISTS Users (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            department TEXT,
            registered_at REAL DEFAULT (strftime('%s', 'now')),
            last_seen_at REAL,
            user_type TEXT DEFAULT 'EMPLOYEE',
            visit_purpose TEXT
        );
        """

        let createVectorsTable = """
        CREATE TABLE IF NOT EXISTS FaceSignatures (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            user_id TEXT,
            vector BLOB,
            created_at REAL DEFAULT (strftime('%s', 'now')),
            FOREIGN KEY(user_id) REFERENCES Users(id) ON DELETE CASCADE
        );
        """

        let createLogsTable = """
        CREATE TABLE IF NOT EXISTS AttendanceLogs (
            id TEXT PRIMARY KEY,
            user_name TEXT,
            timestamp REAL,
            type TEXT DEFAULT 'checkIn'
        );
        """

        let createDailyAttendanceTable = """
        CREATE TABLE IF NOT EXISTS DailyAttendance (
            id TEXT PRIMARY KEY,
            user_no TEXT,
            user_name TEXT,
            date TEXT,
            check_in_time REAL,
            check_out_time REAL,
            UNIQUE(user_name, date)
        );
        """

        let createConsentTable = """
        CREATE TABLE IF NOT EXISTS ConsentLogs (
            id TEXT PRIMARY KEY,
            user_name TEXT,
            consent_version TEXT,
            timestamp REAL
        );
        """

        // Create indexes for faster queries
        let createIndexes = """
        CREATE INDEX IF NOT EXISTS idx_logs_timestamp ON AttendanceLogs(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_logs_user ON AttendanceLogs(user_name);
        CREATE INDEX IF NOT EXISTS idx_daily_date ON DailyAttendance(date);
        CREATE INDEX IF NOT EXISTS idx_signatures_user ON FaceSignatures(user_id);
        """

        execute(sql: createUsersTable)
        execute(sql: createVectorsTable)
        execute(sql: createLogsTable)
        execute(sql: createDailyAttendanceTable)
        execute(sql: createConsentTable)

        for statement in createIndexes.components(separatedBy: ";") where !statement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            execute(sql: statement + ";")
        }
    }

    private func migrateTables() {
        // Try to add columns if they don't exist (SQLite will ignore if they exist or fail safely)
        // Users table migrations
        // SQLite ALTER TABLE does not support non-constant defaults like strftime. 
        // We set default to 0, then update it.
        let addRegisteredAt = "ALTER TABLE Users ADD COLUMN registered_at REAL DEFAULT 0;"
        execute(sql: addRegisteredAt)
        
        // Update existing users to have the current timestamp instead of 0
        let updateRegisteredAt = "UPDATE Users SET registered_at = strftime('%s', 'now') WHERE registered_at = 0;"
        execute(sql: updateRegisteredAt)
        
        let addLastSeenAt = "ALTER TABLE Users ADD COLUMN last_seen_at REAL;"
        execute(sql: addLastSeenAt)

        let addUserType = "ALTER TABLE Users ADD COLUMN user_type TEXT DEFAULT 'EMPLOYEE';"
        execute(sql: addUserType)

        let addVisitPurpose = "ALTER TABLE Users ADD COLUMN visit_purpose TEXT;"
        execute(sql: addVisitPurpose)

        // AttendanceLogs table migrations
        let addType = "ALTER TABLE AttendanceLogs ADD COLUMN type TEXT DEFAULT 'checkIn';"
        execute(sql: addType)

    }

    // MARK: - User Management

    func saveUser(_ user: FaceUser) {
        dbQueue.async { [weak self] in
            self?.saveUserSync(user)
        }
    }

    private func saveUserSync(_ user: FaceUser) {
        var userId = user.id
        var existingUser = false

        let queryUser = "SELECT id FROM Users WHERE name = ? AND user_type = ? LIMIT 1;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, queryUser, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (user.name as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (user.userType.rawValue as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                if let idStr = sqlite3_column_text(stmt, 0) {
                    userId = String(cString: idStr)
                    existingUser = true
                }
            }
        }
        sqlite3_finalize(stmt)

        if !existingUser {
            let insertUser = "INSERT INTO Users (id, name, department, registered_at, user_type, visit_purpose) VALUES (?, ?, ?, ?, ?, ?);"
            if sqlite3_prepare_v2(db, insertUser, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (userId as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (user.name as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (user.department as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 4, user.registeredAt.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 5, (user.userType.rawValue as NSString).utf8String, -1, nil)
                if let visitPurpose = user.visitPurpose {
                    sqlite3_bind_text(stmt, 6, (visitPurpose as NSString).utf8String, -1, nil)
                } else {
                    sqlite3_bind_null(stmt, 6)
                }
                sqlite3_step(stmt)
            } else {
                print("Insert User Error: \(String(cString: sqlite3_errmsg(db)))")
            }
            sqlite3_finalize(stmt)
        }

        let insertVector = "INSERT INTO FaceSignatures (user_id, vector) VALUES (?, ?);"
        if sqlite3_prepare_v2(db, insertVector, -1, &stmt, nil) == SQLITE_OK {
            for signature in user.faceSignatures {
                let data = toData(vector: signature)
                sqlite3_bind_text(stmt, 1, (userId as NSString).utf8String, -1, nil)
                _ = data.withUnsafeBytes { rawBuffer in
                    sqlite3_bind_blob(stmt, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), nil)
                }
                sqlite3_step(stmt)
                sqlite3_reset(stmt)
            }
        } else {
            print("Insert Vector Error: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)

        limitSignatures(for: userId, maxCount: 200)
        loadUsers()
    }

    /// Appends a single confidently-matched embedding to an existing user's signatures,
    /// e.g. from a successful checkIn/checkOut. Cheaper than saveUser() since it skips the
    /// name/user_type lookup and re-inserts nothing but the one vector.
    func appendSignature(userId: String, vector: [Float]) {
        dbQueue.async { [weak self] in
            self?.appendSignatureSync(userId: userId, vector: vector)
        }
    }

    private func appendSignatureSync(userId: String, vector: [Float]) {
        let insertVector = "INSERT INTO FaceSignatures (user_id, vector) VALUES (?, ?);"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, insertVector, -1, &stmt, nil) == SQLITE_OK {
            let data = toData(vector: vector)
            sqlite3_bind_text(stmt, 1, (userId as NSString).utf8String, -1, nil)
            _ = data.withUnsafeBytes { rawBuffer in
                sqlite3_bind_blob(stmt, 2, rawBuffer.baseAddress, Int32(rawBuffer.count), nil)
            }
            sqlite3_step(stmt)
        } else {
            print("Append Signature Error: \(String(cString: sqlite3_errmsg(db)))")
        }
        sqlite3_finalize(stmt)

        limitSignatures(for: userId, maxCount: 200)
        loadUsers()
    }

    func deleteUser(at offsets: IndexSet) {
        for index in offsets {
            let user = users[index]
            let deleteSql = "DELETE FROM Users WHERE id = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, deleteSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (user.id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            // Also delete signatures
            let deleteSignatures = "DELETE FROM FaceSignatures WHERE user_id = ?;"
            if sqlite3_prepare_v2(db, deleteSignatures, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (user.id as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        loadUsers()
    }

    private func limitSignatures(for userId: String, maxCount: Int) {
        var count = 0
        let countSql = "SELECT COUNT(*) FROM FaceSignatures WHERE user_id = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, countSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (userId as NSString).utf8String, -1, nil)
            if sqlite3_step(stmt) == SQLITE_ROW {
                count = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)

        if count > maxCount {
            let deleteCount = count - maxCount
            let deleteSql = """
            DELETE FROM FaceSignatures
            WHERE id IN (
                SELECT id FROM FaceSignatures
                WHERE user_id = ?
                ORDER BY id ASC
                LIMIT ?
            );
            """
            if sqlite3_prepare_v2(db, deleteSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (userId as NSString).utf8String, -1, nil)
                sqlite3_bind_int(stmt, 2, Int32(deleteCount))
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    // MARK: - Attendance Management (Enhanced)

    func checkIn(userName: String, userNo: String = "") {
        let today = AttendanceEntry.todayKey()
        let now = Date()

        dbQueue.async { [weak self] in
            guard let self = self else { return }

            // Check if already checked in today
            let checkSql = "SELECT id FROM DailyAttendance WHERE user_name = ? AND date = ?;"
            var stmt: OpaquePointer?
            var exists = false

            if sqlite3_prepare_v2(self.db, checkSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (userName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (today as NSString).utf8String, -1, nil)
                exists = sqlite3_step(stmt) == SQLITE_ROW
            }
            sqlite3_finalize(stmt)

            if !exists {
                let id = UUID().uuidString
                let insertSql = "INSERT INTO DailyAttendance (id, user_no, user_name, date, check_in_time) VALUES (?, ?, ?, ?, ?);"
                if sqlite3_prepare_v2(self.db, insertSql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 2, (userNo as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 3, (userName as NSString).utf8String, -1, nil)
                    sqlite3_bind_text(stmt, 4, (today as NSString).utf8String, -1, nil)
                    sqlite3_bind_double(stmt, 5, now.timeIntervalSince1970)
                    sqlite3_step(stmt)
                }
                sqlite3_finalize(stmt)

                // Also add to regular logs
                self.addLogSync(name: userName, type: "checkIn")
            }

            DispatchQueue.main.async {
                self.loadTodayAttendance()
                self.loadLogs()
            }
        }
    }

    func checkOut(userName: String) {
        let today = AttendanceEntry.todayKey()
        let now = Date()

        dbQueue.async { [weak self] in
            guard let self = self else { return }

            let updateSql = "UPDATE DailyAttendance SET check_out_time = ? WHERE user_name = ? AND date = ?;"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, updateSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
                sqlite3_bind_text(stmt, 2, (userName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (today as NSString).utf8String, -1, nil)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)

            self.addLogSync(name: userName, type: "checkOut")

            DispatchQueue.main.async {
                self.loadTodayAttendance()
                self.loadLogs()
            }
        }
    }

    func getTodayStatus(for userName: String) -> UserAttendanceStatus {
        guard let entry = todayAttendance[userName] else {
            return .notCheckedIn
        }
        if entry.isCheckedOut {
            return .checkedOut
        } else if entry.isCheckedIn {
            return .checkedIn
        }
        return .notCheckedIn
    }

    func user(named name: String) -> FaceUser? {
        users.first { $0.name == name }
    }

    func addLog(name: String, type: String = "checkIn") {
        dbQueue.async { [weak self] in
            self?.addLogSync(name: name, type: type)
            DispatchQueue.main.async {
                self?.loadLogs()
            }
        }
    }

    private func addLogSync(name: String, type: String) {
        let id = UUID().uuidString
        let timestamp = Date().timeIntervalSince1970
        let insertSql = "INSERT INTO AttendanceLogs (id, user_name, timestamp, type) VALUES (?, ?, ?, ?);"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, insertSql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
            sqlite3_bind_text(stmt, 2, (name as NSString).utf8String, -1, nil)
            sqlite3_bind_double(stmt, 3, timestamp)
            sqlite3_bind_text(stmt, 4, (type as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    func clearLogs() {
        execute(sql: "DELETE FROM AttendanceLogs;")
        loadLogs()
    }

    func clearTodayAttendance() {
        let today = AttendanceEntry.todayKey()
        let sql = "DELETE FROM DailyAttendance WHERE date = ?;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (today as NSString).utf8String, -1, nil)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        loadTodayAttendance()
    }

    func resetAllData() {
        execute(sql: "DELETE FROM FaceSignatures;")
        execute(sql: "DELETE FROM Users;")
        execute(sql: "DELETE FROM AttendanceLogs;")
        execute(sql: "DELETE FROM DailyAttendance;")
        loadUsers()
        loadLogs()
        loadTodayAttendance()
    }

    // MARK: - Loading Data

    private func loadUsers() {
        var newUsers: [FaceUser] = []

        let userSql = "SELECT id, name, department, registered_at, last_seen_at, user_type, visit_purpose FROM Users;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, userSql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                var dept = ""
                if let deptPtr = sqlite3_column_text(stmt, 2) {
                    dept = String(cString: deptPtr)
                }
                let registeredAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                var lastSeenAt: Date? = nil
                if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    lastSeenAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                }
                var userType: FaceUserType = .employee
                if let typePtr = sqlite3_column_text(stmt, 5),
                   let parsed = FaceUserType(rawValue: String(cString: typePtr)) {
                    userType = parsed
                }
                var visitPurpose: String? = nil
                if let purposePtr = sqlite3_column_text(stmt, 6) {
                    visitPurpose = String(cString: purposePtr)
                }

                let signatures = loadSignatures(for: id)
                newUsers.append(FaceUser(id: id, name: name, department: dept, faceSignatures: signatures, registeredAt: registeredAt, lastSeenAt: lastSeenAt, userType: userType, visitPurpose: visitPurpose))
            }
        } else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            print("LoadUsers Error: \(errmsg)")
        }
        sqlite3_finalize(stmt)

        DispatchQueue.main.async {
            print("Loaded \(newUsers.count) users")
            self.users = newUsers
        }
    }

    private func loadSignatures(for userId: String) -> [[Float]] {
        var signatures: [[Float]] = []
        let sql = "SELECT vector FROM FaceSignatures WHERE user_id = ?;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (userId as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let blob = sqlite3_column_blob(stmt, 0) {
                    let bytes = sqlite3_column_bytes(stmt, 0)
                    let data = Data(bytes: blob, count: Int(bytes))
                    signatures.append(toVector(data: data))
                }
            }
        }
        sqlite3_finalize(stmt)
        return signatures
    }

    private func loadLogs() {
        var logs: [AttendanceRecord] = []
        let sql = "SELECT id, user_name, timestamp, type FROM AttendanceLogs ORDER BY timestamp DESC LIMIT 100;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idStr = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let timestamp = sqlite3_column_double(stmt, 2)
                var type = "checkIn"
                if let typePtr = sqlite3_column_text(stmt, 3) {
                    type = String(cString: typePtr)
                }

                if let uuid = UUID(uuidString: idStr) {
                    logs.append(AttendanceRecord(id: uuid, userName: name, timestamp: Date(timeIntervalSince1970: timestamp), type: type))
                }
            }
        }
        sqlite3_finalize(stmt)

        DispatchQueue.main.async {
            self.attendanceLogs = logs
        }
    }

    private func loadTodayAttendance() {
        let today = AttendanceEntry.todayKey()
        var entries: [String: AttendanceEntry] = [:]

        let sql = "SELECT id, user_no, user_name, date, check_in_time, check_out_time FROM DailyAttendance WHERE date = ?;"
        var stmt: OpaquePointer?

        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, (today as NSString).utf8String, -1, nil)
            while sqlite3_step(stmt) == SQLITE_ROW {
                let id = String(cString: sqlite3_column_text(stmt, 0))
                let userNo = String(cString: sqlite3_column_text(stmt, 1))
                let userName = String(cString: sqlite3_column_text(stmt, 2))
                let dateStr = String(cString: sqlite3_column_text(stmt, 3))

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                let date = formatter.date(from: dateStr) ?? Date()

                var checkInTime: Date? = nil
                var checkOutTime: Date? = nil

                if sqlite3_column_type(stmt, 4) != SQLITE_NULL {
                    checkInTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4))
                }
                if sqlite3_column_type(stmt, 5) != SQLITE_NULL {
                    checkOutTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5))
                }

                entries[userName] = AttendanceEntry(
                    id: id,
                    userNo: userNo,
                    userName: userName,
                    date: date,
                    checkInTime: checkInTime,
                    checkOutTime: checkOutTime
                )
            }
        }
        sqlite3_finalize(stmt)

        DispatchQueue.main.async {
            self.todayAttendance = entries
        }
    }

    // MARK: - Consent Logs
    func saveConsent(userName: String, consentVersion: String) {
        let id = UUID().uuidString
        let ts = Date().timeIntervalSince1970
        let insertSql = "INSERT INTO ConsentLogs (id, user_name, consent_version, timestamp) VALUES (?, ?, ?, ?);"
        dbQueue.async { [weak self] in
            guard let self = self else { return }
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(self.db, insertSql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, (id as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 2, (userName as NSString).utf8String, -1, nil)
                sqlite3_bind_text(stmt, 3, (consentVersion as NSString).utf8String, -1, nil)
                sqlite3_bind_double(stmt, 4, ts)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
            DispatchQueue.main.async { self.loadConsentLogs() }
        }
    }

    func loadConsentLogs() {
        var logs: [ConsentRecord] = []
        let sql = "SELECT id, user_name, consent_version, timestamp FROM ConsentLogs ORDER BY timestamp DESC;"
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let idStr = String(cString: sqlite3_column_text(stmt, 0))
                let name = String(cString: sqlite3_column_text(stmt, 1))
                let version = String(cString: sqlite3_column_text(stmt, 2))
                let ts = sqlite3_column_double(stmt, 3)
                logs.append(ConsentRecord(id: idStr, userName: name, consentVersion: version, timestamp: Date(timeIntervalSince1970: ts)))
            }
        }
        sqlite3_finalize(stmt)
        DispatchQueue.main.async { self.consentLogs = logs }
    }

    // MARK: - Backup & Restore

    var backupURL: URL {
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("face_db_backup.sqlite")
    }

    func backupDatabase() {
        sqlite3_close(db)
        db = nil

        let originURL = URL(fileURLWithPath: dbPath)
        do {
            if FileManager.default.fileExists(atPath: backupURL.path) {
                try FileManager.default.removeItem(at: backupURL)
            }
            try FileManager.default.copyItem(at: originURL, to: backupURL)
        } catch {
            print("Backup failed: \(error)")
        }

        openDatabase()
    }

    func restoreFromBackup() {
        guard FileManager.default.fileExists(atPath: backupURL.path) else { return }

        sqlite3_close(db)
        db = nil

        let originURL = URL(fileURLWithPath: dbPath)
        do {
            if FileManager.default.fileExists(atPath: originURL.path) {
                try FileManager.default.removeItem(at: originURL)
            }
            try FileManager.default.copyItem(at: backupURL, to: originURL)
        } catch {
            print("Restore failed: \(error)")
        }

        openDatabase()
        loadUsers()
        loadLogs()
        loadTodayAttendance()
        loadWeeklyStats()
    }

    func loadWeeklyStats() {
        let stats = getWeeklyStats()
        DispatchQueue.main.async {
            self.weeklyStats = stats
        }
    }

    func getWeeklyStats() -> [DayStat] {
        var stats: [DayStat] = []
        let days = ["SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT"]
        
        let sql = """
        SELECT strftime('%w', date) as day_index, COUNT(*) as count
        FROM DailyAttendance
        WHERE date >= date('now', '-7 days')
        GROUP BY day_index;
        """
        
        var stmt: OpaquePointer?
        var results: [Int: Int] = [:]
        
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                let dayIndex = Int(sqlite3_column_int(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                results[dayIndex] = count
            }
        }
        sqlite3_finalize(stmt)
        
        for i in 0..<7 {
            stats.append(DayStat(day: days[i], count: results[i] ?? 0))
        }
        
        return stats
    }

    // MARK: - Helpers

    private func execute(sql: String) {
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let result = sqlite3_step(stmt)
            if result != SQLITE_DONE && result != SQLITE_ROW {
                let errmsg = String(cString: sqlite3_errmsg(db))
                // Ignore "no more rows" error if it's just a PRAGMA or update that returns ROW/DONE differently
                print("Step error: \(errmsg) for SQL: \(sql)")
            }
        } else {
            let errmsg = String(cString: sqlite3_errmsg(db))
            // Ignore "duplicate column name" errors which happen during migration if column exists
            if !errmsg.contains("duplicate column name") {
                print("Prepare error: \(errmsg) for SQL: \(sql)")
            }
        }
        sqlite3_finalize(stmt)
    }

    private func toData(vector: [Float]) -> Data {
        return vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    private func toVector(data: Data) -> [Float] {
        return data.withUnsafeBytes {
            let buffer = $0.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }

}
