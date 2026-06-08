import Foundation

struct Employee: Identifiable, Codable {
    let userNo: String
    let userName: String
    let userNameHuri: String?
    let userNameKr: String?
    let teamName: String?
    let departmentName: String?
    let userDepartment: String?
    let userPositionLevel: String?
    let userImageUrl: String?
    let userType: String?
    var attendanceStatus: String?
    var workIn: String?   // "09:18" or null
    var workOut: String?  // "18:30" or null

    var id: String { userNo }
    var displayName: String { userName }
    var department: String { departmentName ?? userDepartment ?? "" }

    /// Server-side attendance status derived from workIn/workOut
    var serverStatus: ServerAttendanceStatus {
        if let out = workOut, !out.isEmpty, out != "0" { return .checkedOut }
        if let inn = workIn, !inn.isEmpty, inn != "0" { return .checkedIn }
        return .notCheckedIn
    }

    var initials: String {
        let components = userName.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1)) + String(components[1].prefix(1))
        }
        return String(userName.prefix(2))
    }
}

enum ServerAttendanceStatus {
    case notCheckedIn, checkedIn, checkedOut

    var label: String {
        switch self {
        case .notCheckedIn: return "未出勤"
        case .checkedIn:    return "出勤中"
        case .checkedOut:   return "退勤済"
        }
    }
    var color: String {
        switch self {
        case .notCheckedIn: return "gray"
        case .checkedIn:    return "green"
        case .checkedOut:   return "blue"
        }
    }
}

struct EmployeeListResponse: Codable {
    let userInfoList: [Employee]
}

enum AttendanceType: String {
    case checkIn = "出勤"
    case checkOut = "退勤"
}

