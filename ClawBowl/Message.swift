import Foundation

/// 聊天消息模型
struct Message: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let imageData: Data?  // 用户发送的图片（JPEG 压缩后）
    let timestamp: Date
    var status: Status

    /// 工具执行状态文本（以浅色字体显示，类似 Claude 的思考过程）
    var thinkingText: String
    /// 是否正在流式接收内容
    var isStreaming: Bool

    enum Role: String {
        case user
        case assistant
    }

    enum Status {
        case sending
        case sent
        case error
    }

    init(
        role: Role,
        content: String,
        imageData: Data? = nil,
        status: Status = .sent,
        thinkingText: String = "",
        isStreaming: Bool = false
    ) {
        self.id = UUID()
        self.role = role
        self.content = content
        self.imageData = imageData
        self.timestamp = Date()
        self.status = status
        self.thinkingText = thinkingText
        self.isStreaming = isStreaming
    }

    /// 是否包含图片
    var hasImage: Bool { imageData != nil }
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

/// API 请求消息体（用于构建 chat completion 请求）
struct ChatCompletionRequest: Encodable {
    let model: String?
    let messages: [RequestMessage]
    let stream: Bool

    struct RequestMessage: Encodable {
        let role: String
        let content: MessageContent
    }
}

/// 消息内容：纯文本 或 多模态数组（OpenAI Vision 格式）
enum MessageContent: Encodable {
    case text(String)
    case multimodal([ContentPart])

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .text(let string):
            try container.encode(string)
        case .multimodal(let parts):
            try container.encode(parts)
        }
    }
}

/// 多模态内容块
struct ContentPart: Encodable {
    let type: String
    let text: String?
    let image_url: ImageURL?

    struct ImageURL: Encodable {
        let url: String
    }

    /// 创建文本内容块
    static func textPart(_ text: String) -> ContentPart {
        ContentPart(type: "text", text: text, image_url: nil)
    }

    /// 创建图片内容块（base64 data URL）
    static func imagePart(base64: String) -> ContentPart {
        ContentPart(
            type: "image_url",
            text: nil,
            image_url: ImageURL(url: "data:image/jpeg;base64,\(base64)")
        )
    }
}

// MARK: - SSE Streaming Response Models

/// SSE 流式 chunk（OpenAI 兼容 + 自定义 thinking 字段）
struct StreamChunk: Decodable {
    let choices: [StreamChoice]?
}

struct StreamChoice: Decodable {
    let delta: StreamDelta?
    let finish_reason: String?
}

struct StreamDelta: Decodable {
    /// 正常文本内容
    let content: String?
    /// 工具执行状态（自定义字段，用于展示"思考过程"）
    let thinking: String?
}
