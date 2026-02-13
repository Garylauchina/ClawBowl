import Foundation

/// 用户认证服务 – 处理注册、登录、JWT token 管理
@MainActor
class AuthService: ObservableObject {
    static let shared = AuthService()

    @Published var isAuthenticated = false
    @Published var currentUserId: String?

    private let baseURL = "https://prometheusclothing.net/api/v2/auth"
    private let tokenKey = "jwt_access_token"
    private let userIdKey = "auth_user_id"

    private init() {
        // 从 Keychain / UserDefaults 恢复 token
        if let token = UserDefaults.standard.string(forKey: tokenKey),
           !token.isEmpty {
            self.isAuthenticated = true
            self.currentUserId = UserDefaults.standard.string(forKey: userIdKey)
        }
    }

    /// 当前存储的 JWT token
    var accessToken: String? {
        UserDefaults.standard.string(forKey: tokenKey)
    }

    // MARK: - Register

    func register(username: String, password: String) async throws {
        let url = URL(string: "\(baseURL)/register")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 201:
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveToken(tokenResponse)
        case 409:
            throw AuthError.usernameTaken
        default:
            let detail = parseErrorDetail(data) ?? "注册失败"
            throw AuthError.serverError(detail)
        }
    }

    // MARK: - Login

    func login(username: String, password: String) async throws {
        let url = URL(string: "\(baseURL)/login")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 30

        let body: [String: String] = ["username": username, "password": password]
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200:
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveToken(tokenResponse)
        case 401:
            throw AuthError.invalidCredentials
        default:
            let detail = parseErrorDetail(data) ?? "登录失败"
            throw AuthError.serverError(detail)
        }
    }

    // MARK: - Refresh

    func refreshToken() async throws {
        guard let token = accessToken else {
            throw AuthError.notAuthenticated
        }

        let url = URL(string: "\(baseURL)/refresh")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw AuthError.invalidResponse
        }

        if httpResponse.statusCode == 200 {
            let tokenResponse = try JSONDecoder().decode(TokenResponse.self, from: data)
            saveToken(tokenResponse)
        } else if httpResponse.statusCode == 401 {
            logout()
            throw AuthError.tokenExpired
        }
    }

    // MARK: - Logout

    func logout() {
        UserDefaults.standard.removeObject(forKey: tokenKey)
        UserDefaults.standard.removeObject(forKey: userIdKey)
        isAuthenticated = false
        currentUserId = nil
    }

    // MARK: - Private

    private func saveToken(_ response: TokenResponse) {
        UserDefaults.standard.set(response.accessToken, forKey: tokenKey)
        UserDefaults.standard.set(response.userId, forKey: userIdKey)
        isAuthenticated = true
        currentUserId = response.userId
    }

    private func parseErrorDetail(_ data: Data) -> String? {
        if let json = try? JSONDecoder().decode([String: String].self, from: data) {
            return json["detail"]
        }
        return nil
    }
}

// MARK: - Models

struct TokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let userId: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case userId = "user_id"
    }
}

// MARK: - Errors

enum AuthError: LocalizedError {
    case invalidResponse
    case invalidCredentials
    case usernameTaken
    case tokenExpired
    case notAuthenticated
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "服务器响应异常"
        case .invalidCredentials:
            return "用户名或密码错误"
        case .usernameTaken:
            return "用户名已被注册"
        case .tokenExpired:
            return "登录已过期，请重新登录"
        case .notAuthenticated:
            return "未登录"
        case .serverError(let detail):
            return detail
        }
    }
}
