import Foundation
import UIKit

/// SSE 流式事件类型
enum StreamEvent {
    /// 工具执行状态（浅色字体显示）
    case thinking(String)
    /// 正常文本内容增量
    case content(String)
    /// 内容被安全审核过滤（0-chunk 空响应）
    case filtered(String)
    /// Agent 生成的文件（workspace diff 检测）
    case file(FileInfo)
    /// 流结束
    case done
}

/// AI 聊天 API 通信服务 – 直连 OpenClaw Gateway（经 nginx 反代）
actor ChatService {
    static let shared = ChatService()

    private let apiBase = "https://prometheusclothing.net"

    // MARK: - Gateway direct-connect state (set by warmup)

    private var gatewayPath: String?
    private var gatewayToken: String?
    private var sessionKey: String?

    /// Whether gateway info has been configured via warmup
    var isConfigured: Bool { gatewayPath != nil }

    private init() {}

    /// Called after warmup to store gateway connection details.
    func configure(gatewayURL: String, gatewayToken: String, sessionKey: String) {
        self.gatewayPath = gatewayURL
        self.gatewayToken = gatewayToken
        self.sessionKey = sessionKey
    }

    // MARK: - Tool status map (client-side thinking display)

    private static let toolStatusMap: [String: String] = [
        "image": "正在分析图片...",
        "web_search": "正在搜索网页...",
        "web_fetch": "正在读取网页...",
        "read": "正在读取文件...",
        "write": "正在写入文件...",
        "edit": "正在编辑文件...",
        "exec": "正在执行命令...",
        "process": "正在处理任务...",
        "cron": "正在设置定时任务...",
        "memory": "正在检索记忆...",
    ]

    // MARK: - Build request messages

    /// 构建请求消息列表
    /// 图片附件 ≤10MB → base64 嵌入 content 数组（OpenClaw 原生方式）
    /// 大文件 → 先上传到 workspace，消息中引用路径
    private func buildRequestMessages(
        content: String,
        uploadedFilePath: String?,
        attachment: Attachment?,
        history: [Message]
    ) -> [[String: Any]] {
        var requestMessages: [[String: Any]] = []

        let recentHistory = Array(history.suffix(20))
        var indicesToSkip = Set<Int>()
        for i in (0..<recentHistory.count).reversed() {
            let msg = recentHistory[i]
            if msg.role == .assistant && (msg.status == .error || msg.status == .filtered) {
                indicesToSkip.insert(i)
                if i > 0 && recentHistory[i - 1].role == .user {
                    indicesToSkip.insert(i - 1)
                }
            }
        }
        for (i, msg) in recentHistory.enumerated() {
            if indicesToSkip.contains(i) { continue }
            requestMessages.append(["role": msg.role.rawValue, "content": msg.content])
        }

        // Current message
        if let att = attachment, att.isImage, att.data.count <= 10 * 1024 * 1024 {
            // OpenClaw native: embed base64 image in content array
            let b64 = att.data.base64EncodedString()
            let dataUrl = "data:\(att.mimeType);base64,\(b64)"
            var parts: [[String: Any]] = [
                ["type": "image_url", "image_url": ["url": dataUrl]]
            ]
            let text = content.isEmpty ? "请分析这张图片" : content
            parts.insert(["type": "text", "text": text], at: 0)
            requestMessages.append(["role": "user", "content": parts])
        } else {
            var messageText = ""
            if let path = uploadedFilePath {
                messageText += "[用户发送了文件: \(path)]"
            }
            if !content.isEmpty {
                if !messageText.isEmpty { messageText += "\n\n" }
                messageText += content
            }
            if messageText.isEmpty, let att = attachment {
                messageText = att.isImage ? "[图片]" : "[文件: \(att.filename)]"
            }
            requestMessages.append(["role": "user", "content": messageText])
        }

        return requestMessages
    }

    // MARK: - Upload attachment

    /// 上传附件到后端 workspace，返回 workspace 相对路径
    private func uploadAttachment(_ attachment: Attachment) async throws -> String {
        guard let token = await AuthService.shared.accessToken else {
            throw ChatError.notAuthenticated
        }
        guard let url = URL(string: "\(apiBase)/api/v2/files/upload") else {
            throw ChatError.invalidURL
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        var body = Data()
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(attachment.filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(attachment.mimeType)\r\n\r\n".data(using: .utf8)!)
        body.append(attachment.data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let path = json["path"] as? String else {
            throw ChatError.invalidResponse
        }
        return path
    }

    // MARK: - Streaming (SSE) — direct gateway connection

    /// 发送消息并以 SSE 流式接收 AI 回复（直连 OpenClaw Gateway）
    ///
    /// 客户端实现轮次检测：
    /// - tool_calls → 以 thinking 形式显示工具状态
    /// - finish_reason="tool_calls" → 当前内容作为 thinking，开始新轮次
    /// - finish_reason="stop" → 当前内容作为 content（最终回答）
    func sendMessageStream(
        _ content: String,
        attachment: Attachment? = nil,
        history: [Message]
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let gwPath = gatewayPath, let gwToken = gatewayToken else {
            throw ChatError.serviceUnavailable
        }

        // Only upload non-image or large files; images ≤10MB are base64-embedded
        var uploadedPath: String?
        if let att = attachment, !att.isImage || att.data.count > 10 * 1024 * 1024 {
            uploadedPath = try await uploadAttachment(att)
        }

        let messages = buildRequestMessages(
            content: content,
            uploadedFilePath: uploadedPath,
            attachment: attachment,
            history: history
        )

        guard let url = URL(string: "\(apiBase)\(gwPath)/v1/chat/completions") else {
            throw ChatError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(gwToken)", forHTTPHeaderField: "Authorization")
        if let sk = sessionKey {
            request.setValue(sk, forHTTPHeaderField: "x-openclaw-session-key")
        }
        request.timeoutInterval = 300

        let hasImage = attachment?.isImage == true && (attachment?.data.count ?? 0) <= 10 * 1024 * 1024
        let model = hasImage ? "zenmux/z-ai/glm-4.6v-flash-free" : "zenmux/deepseek/deepseek-chat"
        let body: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": true,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validateHTTPResponse(response)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var contentBuffer: [String] = []
                    var seenTools = Set<String>()
                    var thinkingEmitted = false

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" {
                            // Flush remaining buffer as content
                            let final = contentBuffer.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                            if !final.isEmpty {
                                continuation.yield(.content(final))
                            }
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }

                        guard let data = payload.data(using: .utf8),
                              let chunk = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let choices = chunk["choices"] as? [[String: Any]],
                              let choice = choices.first else { continue }

                        let delta = choice["delta"] as? [String: Any] ?? [:]
                        let finishReason = choice["finish_reason"] as? String

                        // Tool calls → emit thinking status
                        if let toolCalls = delta["tool_calls"] as? [[String: Any]] {
                            for tc in toolCalls {
                                if let fn = tc["function"] as? [String: Any],
                                   let name = fn["name"] as? String, !name.isEmpty,
                                   !seenTools.contains(name) {
                                    seenTools.insert(name)
                                    let status = Self.toolStatusMap[name] ?? "正在执行 \(name)..."
                                    let prefix = thinkingEmitted ? "\n" : ""
                                    continuation.yield(.thinking(prefix + status + "\n"))
                                    thinkingEmitted = true
                                }
                            }
                        }

                        // Content text → buffer
                        if let text = delta["content"] as? String, !text.isEmpty {
                            contentBuffer.append(text)
                            // Stream as thinking for real-time feedback
                            continuation.yield(.thinking(text))
                            thinkingEmitted = true
                        }

                        // Turn boundary: tool_calls → flush buffer as thinking, reset
                        if finishReason == "tool_calls" {
                            contentBuffer.removeAll()
                            if thinkingEmitted {
                                continuation.yield(.thinking("\n\n"))
                            }
                        }

                        // Final answer: stop → emit buffer as content
                        if finishReason == "stop" {
                            let final = contentBuffer.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                            if !final.isEmpty {
                                continuation.yield(.content(final))
                            }
                            contentBuffer.removeAll()
                        }
                    }
                    // Stream ended without [DONE]
                    let final = contentBuffer.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                    if !final.isEmpty {
                        continuation.yield(.content(final))
                    }
                    continuation.yield(.done)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    // MARK: - Stream cancellation

    /// 取消当前活跃的流 — 直连模式下只需取消客户端 URLSession 即可
    func cancelChat() async {
        // With direct connect, cancelling the Task (which cancels URLSession)
        // is sufficient. No backend endpoint needed.
    }

    // History is handled by local MessageStore persistence.
    // On logout MessageStore.clear() wipes the cache, new session starts fresh.

    // MARK: - Session management

    /// 重置会话（请求后端销毁并重建 OpenClaw 实例）
    func resetSession() async {
        guard let token = await AuthService.shared.accessToken else { return }

        guard let url = URL(string: "\(apiBase)/api/v2/instance/clear") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        _ = try? await URLSession.shared.data(for: request)

        // Clear gateway config — will be re-configured on next warmup
        gatewayPath = nil
        gatewayToken = nil
        sessionKey = nil
    }

    // MARK: - HTTP validation

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            switch httpResponse.statusCode {
            case 401:
                Task { try? await AuthService.shared.refreshToken() }
                throw ChatError.notAuthenticated
            case 429:
                throw ChatError.rateLimited
            case 500:
                throw ChatError.serverError
            case 502, 503:
                throw ChatError.serviceUnavailable
            default:
                throw ChatError.httpError(httpResponse.statusCode)
            }
        }
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
    case notAuthenticated
    case uploadFailed
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
        case .uploadFailed:
            return "附件上传失败，请重试"
        case .httpError(let code):
            return "请求失败 (\(code))"
        }
    }
}
