import Foundation

/// AI 聊天 API 通信服务
actor ChatService {
    static let shared = ChatService()

    private let baseURL = "https://prometheusclothing.net/api/chat"
    private let model = "openclaw:main"

    /// 用户 ID（用于 OpenClaw 会话保持）
    private let userId: String

    private init() {
        // 从 UserDefaults 获取或生成用户 ID
        if let stored = UserDefaults.standard.string(forKey: "chat_user_id") {
            self.userId = stored
        } else {
            let newId = UUID().uuidString
            UserDefaults.standard.set(newId, forKey: "chat_user_id")
            self.userId = newId
        }
    }

    /// 发送消息并获取 AI 回复
    /// - Parameters:
    ///   - content: 用户消息内容
    ///   - history: 历史消息（用于上下文）
    /// - Returns: AI 回复文本
    func sendMessage(_ content: String, history: [Message]) async throws -> String {
        guard let url = URL(string: baseURL) else {
            throw ChatError.invalidURL
        }

        // 构建消息列表（最近 10 轮对话 = 20 条消息）
        var requestMessages: [ChatCompletionRequest.RequestMessage] = []

        let recentHistory = history.suffix(20)
        for msg in recentHistory {
            requestMessages.append(.init(role: msg.role.rawValue, content: msg.content))
        }
        requestMessages.append(.init(role: "user", content: content))

        let requestBody = ChatCompletionRequest(
            model: model,
            messages: requestMessages,
            user: userId,
            stream: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            switch httpResponse.statusCode {
            case 429:
                throw ChatError.rateLimited
            case 500:
                throw ChatError.serverError
            case 503:
                throw ChatError.serviceUnavailable
            default:
                throw ChatError.httpError(httpResponse.statusCode)
            }
        }

        let decoder = JSONDecoder()
        let completionResponse = try decoder.decode(ChatCompletionResponse.self, from: data)

        guard let content = completionResponse.choices?.first?.message?.content else {
            throw ChatError.emptyResponse
        }

        return content
    }

    /// 重置会话（生成新的 userId）
    func resetSession() {
        let newId = UUID().uuidString
        UserDefaults.standard.set(newId, forKey: "chat_user_id")
    }
}

/// 聊天错误类型
enum ChatError: LocalizedError {
    case invalidURL
    case invalidResponse
    case emptyResponse
    case rateLimited
    case serverError
    case serviceUnavailable
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "无效的请求地址"
        case .invalidResponse:
            return "服务器响应异常"
        case .emptyResponse:
            return "AI 未返回内容"
        case .rateLimited:
            return "请求过于频繁，请稍后再试"
        case .serverError:
            return "服务器内部错误"
        case .serviceUnavailable:
            return "AI 服务暂时不可用"
        case .httpError(let code):
            return "请求失败 (\(code))"
        }
    }
}
