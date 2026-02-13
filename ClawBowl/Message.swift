import Foundation

/// 聊天消息模型
struct Message: Identifiable, Equatable {
    let id: UUID
    let role: Role
    let content: String
    let timestamp: Date
    var status: Status

    enum Role: String {
        case user
        case assistant
    }

    enum Status {
        case sending
        case sent
        case error
    }

    init(role: Role, content: String, status: Status = .sent) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.timestamp = Date()
        self.status = status
    }
}

/// OpenAI 兼容的 API 响应模型
struct ChatCompletionResponse: Decodable {
    let id: String?
    let choices: [Choice]?

    struct Choice: Decodable {
        let index: Int?
        let message: ResponseMessage?
    }

    struct ResponseMessage: Decodable {
        let role: String?
        let content: String?
    }
}

/// API 请求体
struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [RequestMessage]
    let user: String?
    let stream: Bool

    struct RequestMessage: Encodable {
        let role: String
        let content: String
    }
}
