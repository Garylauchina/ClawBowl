import Foundation

/// 按 sessionKey 分桶的会话缓存，避免串话题
enum SessionStore {
    private static let fileManager = FileManager.default
    private static var cacheDir: URL {
        let dir = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("sessions", isDirectory: true)
    }

    private static func fileURL(sessionKey: String) -> URL {
        let safe = sessionKey.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        if !fileManager.fileExists(atPath: cacheDir.path) {
            try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        }
        return cacheDir.appendingPathComponent("\(safe).json")
    }

    /// 轻量持久化模型（不含附件二进制）
    private struct PersistedMessage: Codable {
        let role: String
        let content: String
        let timestamp: Date
        let attachmentLabel: String?
        let serverId: String?
    }

    /// 保存某会话最近 N 条消息
    static func save(_ messages: [Message], sessionKey: String, maxCount: Int = 500) {
        let toSave = maxCount < messages.count ? Array(messages.suffix(maxCount)) : messages
        let persisted = toSave.map { msg -> PersistedMessage in
            var label: String? = nil
            if let att = msg.attachment {
                label = att.isImage ? "[图片]" : "[文件: \(att.filename)]"
            }
            return PersistedMessage(
                role: msg.role.rawValue,
                content: msg.content,
                timestamp: msg.timestamp,
                attachmentLabel: label,
                serverId: msg.serverId
            )
        }
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: fileURL(sessionKey: sessionKey), options: .atomic)
        }
    }

    /// 加载某会话已持久化的消息
    static func load(sessionKey: String) -> [Message]? {
        let url = fileURL(sessionKey: sessionKey)
        guard let data = try? Data(contentsOf: url),
              let persisted = try? JSONDecoder().decode([PersistedMessage].self, from: data),
              !persisted.isEmpty else {
            return nil
        }
        return persisted.compactMap { p in
            guard let role = Message.Role(rawValue: p.role) else { return nil }
            let displayContent: String
            if let label = p.attachmentLabel, p.content.isEmpty {
                displayContent = label
            } else {
                displayContent = p.content
            }
            return Message(serverId: p.serverId, role: role, content: displayContent, timestamp: p.timestamp)
        }
    }

    /// 清空某会话持久化
    static func clear(sessionKey: String) {
        try? fileManager.removeItem(at: fileURL(sessionKey: sessionKey))
    }

    /// 列出已缓存的 sessionKey（用于话题列表）
    static func listCachedSessionKeys() -> [String] {
        guard fileManager.fileExists(atPath: cacheDir.path),
              let contents = try? fileManager.contentsOfDirectory(atPath: cacheDir.path) else {
            return []
        }
        return contents
            .filter { $0.hasSuffix(".json") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }
}
