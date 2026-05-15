import Foundation

// MARK: - Enhanced Attendance Record
struct AttendanceEntry: Identifiable, Codable {
    let id: String
    let userNo: String
    let userName: String
    let date: Date
    var checkInTime: Date?
    var checkOutTime: Date?

    var isCheckedIn: Bool { checkInTime != nil }
    var isCheckedOut: Bool { checkOutTime != nil }
    var isComplete: Bool { isCheckedIn && isCheckedOut }

    var workDuration: TimeInterval? {
        guard let checkIn = checkInTime, let checkOut = checkOutTime else { return nil }
        return checkOut.timeIntervalSince(checkIn)
    }

    var workDurationFormatted: String {
        guard let duration = workDuration else { return "--:--" }
        let hours = Int(duration) / 3600
        let minutes = (Int(duration) % 3600) / 60
        return String(format: "%d時間%02d分", hours, minutes)
    }

    var checkInTimeFormatted: String {
        guard let time = checkInTime else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: time)
    }

    var checkOutTimeFormatted: String {
        guard let time = checkOutTime else { return "--:--" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: time)
    }

    var dateFormatted: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM/dd (E)"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }

    static func todayKey(for date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Daily Summary
struct DailySummary {
    let date: Date
    let totalEmployees: Int
    let checkedInCount: Int
    let checkedOutCount: Int

    var attendanceRate: Double {
        guard totalEmployees > 0 else { return 0 }
        return Double(checkedInCount) / Double(totalEmployees) * 100
    }
}

// MARK: - User Status
enum UserAttendanceStatus: String, Codable {
    case notCheckedIn = "未出勤"
    case checkedIn = "出勤中"
    case checkedOut = "退勤済"

    var color: String {
        switch self {
        case .notCheckedIn: return "gray"
        case .checkedIn: return "green"
        case .checkedOut: return "blue"
        }
    }

    var icon: String {
        switch self {
        case .notCheckedIn: return "circle"
        case .checkedIn: return "circle.fill"
        case .checkedOut: return "checkmark.circle.fill"
        }
    }
}
