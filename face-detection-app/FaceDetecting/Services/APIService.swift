import Foundation
import Combine

class APIService: ObservableObject {
    static let shared = APIService()

    @Published var employees: [Employee] = []
    @Published var visitors: [Visitor] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private let baseURL = "https://flowing-typically-mole.ngrok-free.app/api"
    private let apiKey = "111"

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
        request.setValue(apiKey, forHTTPHeaderField: "API-KEY")
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

    // MARK: - Work In (출근)

    func setWorkIn(userNo: String, userName: String) async throws {
        guard let url = URL(string: "\(baseURL)/v1/setUserWorkIn") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "API-KEY")
        request.httpBody = try JSONEncoder().encode(["userNo": userNo, "userName": userName])
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? Int, status != 200 {
            throw APIError.serverError
        }
    }

    // MARK: - Visitors

    func registerVisitor(company: String, name: String, purpose: String, photoBase64: String?) async throws {
        guard let url = URL(string: "\(baseURL)/v1/setVisitor") else {
            throw APIError.invalidURL
        }

        let body = VisitorRegistrationRequest(
            purpose: purpose,
            company: company,
            name: name,
            memo: nil,
            photo: photoBase64 ?? "1",
            photo2: nil
        )

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "API-KEY")
        request.httpBody = try JSONEncoder().encode(body)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? Int, status != 200 {
            throw APIError.serverError
        }
    }

    func fetchVisitors(date: String? = nil) async throws -> [Visitor] {
        guard let url = URL(string: "\(baseURL)/v1/visitorList") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "API-KEY")
        if let date {
            request.httpBody = try JSONEncoder().encode(["date1": date])
        } else {
            request.httpBody = try JSONEncoder().encode([String: String]())
        }
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        let decoded = try JSONDecoder().decode(VisitorListResponse.self, from: data)
        return decoded.visitorCheckInList ?? decoded.visitorAllList ?? decoded.visitorEntityList ?? []
    }

    func checkOutVisitor(no: String) async throws {
        guard let url = URL(string: "\(baseURL)/v1/checkOutVisitor") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "API-KEY")
        request.httpBody = try JSONEncoder().encode(["no": no])
        request.timeoutInterval = 10

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }
    }

    // MARK: - Work Out (퇴근)

    func setWorkOut(userNo: String, userName: String) async throws {
        guard let url = URL(string: "\(baseURL)/v1/setUserWorkOut") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "API-KEY")
        request.httpBody = try JSONEncoder().encode(["userNo": userNo, "userName": userName])
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.serverError
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? Int, status != 200 {
            throw APIError.serverError
        }
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

    @MainActor
    func loadVisitors() async {
        do {
            visitors = try await fetchVisitors()
        } catch {
            print("[APIService] loadVisitors error: \(error)")
        }
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

struct Visitor: Identifiable, Codable {
    let no: String
    let purpose: String?
    let company: String?
    let name: String
    let memo: String?
    let photo: String?
    let photo2: String?
    let registDate: String?
    let checkIn: String?
    let checkOut: String?
    let deleteFlg: String?

    var id: String { no }

    enum CodingKeys: String, CodingKey {
        case no, purpose, company, name, memo, photo, photo2, registDate, checkIn, checkOut, deleteFlg
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        no = Self.decodeString(container, forKey: .no) ?? UUID().uuidString
        purpose = Self.decodeString(container, forKey: .purpose)
        company = Self.decodeString(container, forKey: .company)
        name = Self.decodeString(container, forKey: .name) ?? ""
        memo = Self.decodeString(container, forKey: .memo)
        photo = Self.decodeString(container, forKey: .photo)
        photo2 = Self.decodeString(container, forKey: .photo2)
        registDate = Self.decodeString(container, forKey: .registDate)
        checkIn = Self.decodeString(container, forKey: .checkIn)
        checkOut = Self.decodeString(container, forKey: .checkOut)
        deleteFlg = Self.decodeString(container, forKey: .deleteFlg)
    }

    private static func decodeString(_ container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) -> String? {
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return value
        }
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return String(value)
        }
        return nil
    }
}

struct VisitorListResponse: Codable {
    let visitorCheckInList: [Visitor]?
    let visitorAllList: [Visitor]?
    let visitorEntityList: [Visitor]?
}

struct VisitorRegistrationRequest: Codable {
    let purpose: String
    let company: String
    let name: String
    let memo: String?
    let photo: String
    let photo2: String?
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
