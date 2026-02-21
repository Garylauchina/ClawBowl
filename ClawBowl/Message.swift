import Foundation

// MARK: - Attachment (通用附件：图片或文件)

/// 通用附件模型，可表示图片或任意文件
struct Attachment: Equatable {
    let filename: String     // "photo.jpg" 或 "report.pdf"
    let data: Data
    let mimeType: String     // "image/jpeg", "application/pdf", etc.

    /// 便于 UI 判断是否显示缩略图
    var isImage: Bool {
        mimeType.hasPrefix("image/")
    }

    /// 人类可读的文件大小
    var formattedSize: String {
        let bytes = Double(data.count)
        if bytes < 1024 {
            return "\(Int(bytes)) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", bytes / 1024)
        } else {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        }
    }
}

// MARK: - FileInfo (Agent 生成的文件)

/// Agent 在 workspace 中生成的文件信息（通过 SSE file 事件传递）
struct FileInfo: Identifiable, Equatable, Codable {
    let id: UUID
    let name: String       // "chart.png"
    let path: String       // "output/chart.png" (workspace 相对路径)
    let size: Int          // bytes
    let mimeType: String   // "image/png"
    /// Base64-encoded image data (inline from SSE, bypasses CDN download)
    let inlineData: String?

    var isImage: Bool { mimeType.hasPrefix("image/") }

    var formattedSize: String {
        let bytes = Double(size)
        if bytes < 1024 {
            return "\(Int(bytes)) B"
        } else if bytes < 1024 * 1024 {
            return String(format: "%.1f KB", bytes / 1024)
        } else {
            return String(format: "%.1f MB", bytes / (1024 * 1024))
        }
    }

    enum CodingKeys: String, CodingKey {
        case name, path, size
        case mimeType = "type"
        case inlineData = "data"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = UUID()
        self.name = try container.decode(String.self, forKey: .name)
        self.path = try container.decode(String.self, forKey: .path)
        self.size = try container.decode(Int.self, forKey: .size)
        self.mimeType = try container.decode(String.self, forKey: .mimeType)
        self.inlineData = try container.decodeIfPresent(String.self, forKey: .inlineData)
    }

    init(name: String, path: String, size: Int, mimeType: String, inlineData: String? = nil) {
        self.id = UUID()
        self.name = name
        self.path = path
        self.size = size
        self.mimeType = mimeType
        self.inlineData = inlineData
    }
}

// MARK: - Message

/// 聊天消息模型
struct Message: Identifiable, Equatable {
    let id: UUID
    let role: Role
    var content: String
    let attachment: Attachment?  // 用户发送的附件（图片或文件）
    let timestamp: Date
    var status: Status

    /// 工具执行状态文本（以浅色字体显示，类似 Claude 的思考过程）
    var thinkingText: String
    /// 是否正在流式接收内容
    var isStreaming: Bool
    /// Agent 在 workspace 中生成的文件列表（通过 SSE file 事件检测）
    var files: [FileInfo]
    /// 后端 event_id，用于与服务器历史同步去重
    var eventId: String?

    static func == (lhs: Message, rhs: Message) -> Bool {
        lhs.id == rhs.id &&
        lhs.content == rhs.content &&
        lhs.thinkingText == rhs.thinkingText &&
        lhs.status == rhs.status &&
        lhs.isStreaming == rhs.isStreaming &&
        lhs.files.count == rhs.files.count
    }

    enum Role: String, Codable {
        case user
        case assistant
    }

    enum Status: String, Codable {
        case sending
        case sent
        case error
        case filtered
    }

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        attachment: Attachment? = nil,
        timestamp: Date = Date(),
        status: Status = .sent,
        thinkingText: String = "",
        isStreaming: Bool = false,
        files: [FileInfo] = [],
        eventId: String? = nil
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.attachment = attachment
        self.timestamp = timestamp
        self.status = status
        self.thinkingText = thinkingText
        self.isStreaming = isStreaming
        self.files = files
        self.eventId = eventId
    }

    /// 是否包含附件
    var hasAttachment: Bool { attachment != nil }
    /// 是否包含图片附件
    var hasImage: Bool { attachment?.isImage ?? false }
    /// 是否包含 Agent 生成的文件
    var hasFiles: Bool { !files.isEmpty }
}

// MARK: - Message Persistence

/// 轻量持久化模型（不含附件二进制数据，只保留文本信息）
private struct PersistedMessage: Codable {
    let role: String
    let content: String
    let timestamp: Date
    let attachmentLabel: String?  // "[图片]" 或 "[文件: xxx]" 或 nil
}

/// 消息持久化工具 — 将聊天记录保存到本地 JSON 文件
enum MessageStore {
    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("chat_messages.json")
    }

    /// 保存消息列表（最多保留最近 200 条，更早的按需从后端分页拉取）
    static func save(_ messages: [Message]) {
        let recent = messages.suffix(200)
        let persisted = recent.map { msg -> PersistedMessage in
            var label: String? = nil
            if let att = msg.attachment {
                label = att.isImage ? "[图片]" : "[文件: \(att.filename)]"
            }
            return PersistedMessage(
                role: msg.role.rawValue,
                content: msg.content,
                timestamp: msg.timestamp,
                attachmentLabel: label
            )
        }

        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 加载已持久化的消息
    static func load() -> [Message]? {
        guard let data = try? Data(contentsOf: fileURL),
              let persisted = try? JSONDecoder().decode([PersistedMessage].self, from: data),
              !persisted.isEmpty else {
            return nil
        }

        return persisted.compactMap { p in
            guard let role = Message.Role(rawValue: p.role) else { return nil }
            // 附件只保留标签文本，不恢复二进制数据
            let displayContent: String
            if let label = p.attachmentLabel, p.content.isEmpty {
                displayContent = label
            } else if p.attachmentLabel != nil {
                displayContent = p.content
            } else {
                displayContent = p.content
            }
            return Message(role: role, content: displayContent, timestamp: p.timestamp)
        }
    }

    /// 清空持久化数据
    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

