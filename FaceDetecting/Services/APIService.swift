import Foundation
import Combine

class APIService: ObservableObject {
    static let shared = APIService()

    @Published var employees: [Employee] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // Set to true for local mock data, false for actual API calls
    private let useMockData = true

    // API Base URL (configure for production)
    private let baseURL = "https://api.example.com"

    private init() {}

    // MARK: - Employee List

    func fetchEmployees() async throws -> [Employee] {
        if useMockData {
            return try await fetchMockEmployees()
        } else {
            return try await fetchRemoteEmployees()
        }
    }

    private func fetchMockEmployees() async throws -> [Employee] {
        guard let url = Bundle.main.url(forResource: "employees", withExtension: "json") else {
            throw APIError.fileNotFound
        }

        let data = try Data(contentsOf: url)
        let response = try JSONDecoder().decode(EmployeeListResponse.self, from: data)
        return response.userInfoList
    }

    private func fetchRemoteEmployees() async throws -> [Employee] {
        guard let url = URL(string: "\(baseURL)/api/getUserInfos") else {
            throw APIError.invalidURL
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        let decoded = try JSONDecoder().decode(EmployeeListResponse.self, from: data)
        return decoded.userInfoList
    }

    // MARK: - Check In (출근)

    func checkIn(userNo: String, userName: String) async throws -> AttendanceResult {
        if useMockData {
            return mockCheckIn(userNo: userNo, userName: userName)
        } else {
            return try await remoteCheckIn(userNo: userNo, userName: userName)
        }
    }

    private func mockCheckIn(userNo: String, userName: String) -> AttendanceResult {
        // Simulate network delay
        if let index = employees.firstIndex(where: { $0.userNo == userNo }) {
            employees[index].attendanceStatus = "出勤中"
        }

        return AttendanceResult(
            success: true,
            message: "\(userName)さんの出勤を記録しました",
            employee: employees.first(where: { $0.userNo == userNo }),
            type: .checkIn
        )
    }

    private func remoteCheckIn(userNo: String, userName: String) async throws -> AttendanceResult {
        guard let url = URL(string: "\(baseURL)/api/setUserWorkIn") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["userNo": userNo, "userName": userName]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        return AttendanceResult(
            success: true,
            message: "\(userName)さんの出勤を記録しました",
            employee: employees.first(where: { $0.userNo == userNo }),
            type: .checkIn
        )
    }

    // MARK: - Check Out (퇴근)

    func checkOut(userNo: String, userName: String) async throws -> AttendanceResult {
        if useMockData {
            return mockCheckOut(userNo: userNo, userName: userName)
        } else {
            return try await remoteCheckOut(userNo: userNo, userName: userName)
        }
    }

    private func mockCheckOut(userNo: String, userName: String) -> AttendanceResult {
        if let index = employees.firstIndex(where: { $0.userNo == userNo }) {
            employees[index].attendanceStatus = "退勤済"
        }

        return AttendanceResult(
            success: true,
            message: "\(userName)さんの退勤を記録しました",
            employee: employees.first(where: { $0.userNo == userNo }),
            type: .checkOut
        )
    }

    private func remoteCheckOut(userNo: String, userName: String) async throws -> AttendanceResult {
        guard let url = URL(string: "\(baseURL)/api/setUserWorkOut") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = ["userNo": userNo, "userName": userName]
        request.httpBody = try JSONEncoder().encode(body)

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        return AttendanceResult(
            success: true,
            message: "\(userName)さんの退勤を記録しました",
            employee: employees.first(where: { $0.userNo == userNo }),
            type: .checkOut
        )
    }

    // MARK: - Load Employees (Published)

    @MainActor
    func loadEmployees() async {
        isLoading = true
        errorMessage = nil

        do {
            employees = try await fetchEmployees()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    // MARK: - Visitor Management
    
    func reportVisitor(name: String, purpose: String) async throws {
        print("Visitor Arrived: \(name), Purpose: \(purpose)")
        // Mock HR API notification
        try await Task.sleep(nanoseconds: 1 * 1_000_000_000)
    }
}

enum APIError: Error, LocalizedError {
    case fileNotFound
    case invalidURL
    case serverError
    case decodingError

    var errorDescription: String? {
        switch self {
        case .fileNotFound:
            return "データファイルが見つかりません"
        case .invalidURL:
            return "無効なURLです"
        case .serverError:
            return "サーバーエラーが発生しました"
        case .decodingError:
            return "データの解析に失敗しました"
        }
    }
}
