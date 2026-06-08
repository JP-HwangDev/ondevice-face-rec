import Foundation
import Combine

class APIService: ObservableObject {
    static let shared = APIService()

    @Published var employees: [Employee] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let baseURL = "http://192.168.12.7:9000/api"

    private init() {}

    // MARK: - Employee List

    func fetchEmployees() async throws -> [Employee] {
        return try await fetchRemoteEmployees()
    }

    private func fetchRemoteEmployees() async throws -> [Employee] {
        guard let url = URL(string: "\(baseURL)/v1/getUserInfos") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode([String: String]())
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        let decoded = try JSONDecoder().decode(EmployeeListResponse.self, from: data)
        return decoded.userInfoList
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
            print("[APIService] loadEmployees error: \(error)")
        }
        isLoading = false
    }

    /// Silent refresh — no loading indicator (used after attendance actions)
    @MainActor
    func silentRefresh() async {
        do {
            employees = try await fetchEmployees()
        } catch {
            print("[APIService] silentRefresh error: \(error)")
        }
    }

    /// Find employee by userName
    func employee(named name: String) -> Employee? {
        employees.first { $0.userName == name }
    }

}

enum APIError: Error, LocalizedError {
    case invalidURL
    case serverError
    case decodingError

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "無効なURLです"
        case .serverError:
            return "サーバーエラーが発生しました"
        case .decodingError:
            return "データの解析に失敗しました"
        }
    }
}
