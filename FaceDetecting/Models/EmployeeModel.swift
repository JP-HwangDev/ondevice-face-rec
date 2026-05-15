import Foundation

struct Employee: Identifiable, Codable {
    let userNo: String
    let userName: String
    let userNameHuri: String
    let teamName: String
    var attendanceStatus: String
    let userImageUrl: String?

    var id: String { userNo }

    var displayName: String {
        userName
    }

    var initials: String {
        let components = userName.components(separatedBy: " ")
        if components.count >= 2 {
            return String(components[0].prefix(1)) + String(components[1].prefix(1))
        }
        return String(userName.prefix(2))
    }
}

struct EmployeeListResponse: Codable {
    let userInfoList: [Employee]
}

enum AttendanceType: String {
    case checkIn = "出勤"
    case checkOut = "退勤"
}

struct AttendanceResult {
    let success: Bool
    let message: String
    let employee: Employee?
    let type: AttendanceType
}
