import Foundation
import Security

// MARK: - Keychain Helper

/// 轻量 Keychain 封装，用于安全存储 JWT token
private enum KeychainHelper {
    static let service = "com.gangliu.ClawBowl"

    static func save(_ value: String, forKey key: String) {
        guard let data = value.data(using: .utf8) else { return }

        // 先删除旧值
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        // 写入新值
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    static func load(forKey key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(forKey key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

// MARK: - AuthService

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
        // 从旧 UserDefaults 迁移到 Keychain（一次性）
        migrateFromUserDefaultsIfNeeded()

        // 从 Keychain 恢复 token
        if let token = KeychainHelper.load(forKey: tokenKey), !token.isEmpty {
            self.isAuthenticated = true
            self.currentUserId = KeychainHelper.load(forKey: userIdKey)
        }
    }

    /// 当前存储的 JWT token
    var accessToken: String? {
        KeychainHelper.load(forKey: tokenKey)
    }

    // MARK: - Register

    func register(username: String, password: String) async throws {
        guard let url = URL(string: "\(baseURL)/register") else {
            throw AuthError.invalidURL
        }

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
        guard let url = URL(string: "\(baseURL)/login") else {
            throw AuthError.invalidURL
        }

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

        guard let url = URL(string: "\(baseURL)/refresh") else {
            throw AuthError.invalidURL
        }

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
        KeychainHelper.delete(forKey: tokenKey)
        KeychainHelper.delete(forKey: userIdKey)
        isAuthenticated = false
        currentUserId = nil
    }

    // MARK: - Private

    private func saveToken(_ response: TokenResponse) {
        KeychainHelper.save(response.accessToken, forKey: tokenKey)
        KeychainHelper.save(response.userId, forKey: userIdKey)
        isAuthenticated = true
        currentUserId = response.userId
    }

    private func parseErrorDetail(_ data: Data) -> String? {
        if let json = try? JSONDecoder().decode([String: String].self, from: data) {
            return json["detail"]
        }
        return nil
    }

    /// 一次性迁移：将旧 UserDefaults 存储的 token 迁移到 Keychain
    private func migrateFromUserDefaultsIfNeeded() {
        let defaults = UserDefaults.standard
        if let oldToken = defaults.string(forKey: tokenKey), !oldToken.isEmpty {
            KeychainHelper.save(oldToken, forKey: tokenKey)
            if let oldUserId = defaults.string(forKey: userIdKey) {
                KeychainHelper.save(oldUserId, forKey: userIdKey)
            }
            // 清除旧存储
            defaults.removeObject(forKey: tokenKey)
            defaults.removeObject(forKey: userIdKey)
        }
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
    case invalidURL
    case invalidResponse
    case invalidCredentials
    case usernameTaken
    case tokenExpired
    case notAuthenticated
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的请求地址"
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
