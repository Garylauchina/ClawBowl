import Foundation

/// AI 聊天 API 通信服务 – 通过 Orchestrator 代理到用户专属的 OpenClaw 实例
actor ChatService {
    static let shared = ChatService()

    private let baseURL = "https://prometheusclothing.net/api/v2/chat"

    private init() {}

    /// 发送消息并获取 AI 回复
    /// - Parameters:
    ///   - content: 用户消息内容
    ///   - history: 历史消息（用于上下文）
    /// - Returns: AI 回复文本
    func sendMessage(_ content: String, history: [Message]) async throws -> String {
        // 获取 JWT token
        guard let token = await AuthService.shared.accessToken else {
            throw ChatError.notAuthenticated
        }

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

        let requestBody = ChatRequest(
            messages: requestMessages,
            stream: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120  // AI 回复 + 可能的容器启动时间

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            switch httpResponse.statusCode {
            case 401:
                // Token 过期，尝试刷新
                try? await AuthService.shared.refreshToken()
                throw ChatError.notAuthenticated
            case 429:
                throw ChatError.rateLimited
            case 500:
                throw ChatError.serverError
            case 502:
                throw ChatError.serviceUnavailable
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

    /// 重置会话（请求后端销毁并重建 OpenClaw 实例）
    func resetSession() async {
        guard let token = await AuthService.shared.accessToken else { return }

        guard let url = URL(string: "https://prometheusclothing.net/api/v2/instance/clear") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        _ = try? await URLSession.shared.data(for: request)
    }
}

/// v2 聊天请求体（Orchestrator 格式）
struct ChatRequest: Encodable {
    let messages: [ChatCompletionRequest.RequestMessage]
    let stream: Bool
}

/// 聊天错误类型
enum ChatError: LocalizedError {
    case invalidURL
    case invalidResponse
    case emptyResponse
    case rateLimited
    case serverError
    case serviceUnavailable
    case notAuthenticated
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
            return "AI 服务正在启动，请稍后重试"
        case .notAuthenticated:
            return "请先登录"
        case .httpError(let code):
            return "请求失败 (\(code))"
        }
    }
}
