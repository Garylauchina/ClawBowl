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
    /// 流结束
    case done
}

/// AI 聊天 API 通信服务 – 通过 Orchestrator 代理到用户专属的 OpenClaw 实例
actor ChatService {
    static let shared = ChatService()

    private let baseURL = "https://prometheusclothing.net/api/v2/chat"

    private init() {}

    // MARK: - Build request messages (shared by both modes)

    /// 构建 API 请求消息列表（支持图片和通用文件附件）
    private func buildRequestMessages(
        content: String,
        attachment: Attachment?,
        history: [Message]
    ) -> [ChatCompletionRequest.RequestMessage] {
        var requestMessages: [ChatCompletionRequest.RequestMessage] = []

        // 历史消息（最近 20 条），附件用文本标记代替
        // 兜底过滤：跳过 .error/.filtered 状态的 assistant 消息及其前面紧邻的 user 消息
        let recentHistory = Array(history.suffix(20))
        var indicesToSkip = Set<Int>()
        for i in (0..<recentHistory.count).reversed() {
            let msg = recentHistory[i]
            if msg.role == .assistant && (msg.status == .error || msg.status == .filtered) {
                indicesToSkip.insert(i)
                // 找前面紧邻的 user 消息
                if i > 0 && recentHistory[i - 1].role == .user {
                    indicesToSkip.insert(i - 1)
                }
            }
        }
        for (i, msg) in recentHistory.enumerated() {
            if indicesToSkip.contains(i) { continue }
            if let att = msg.attachment {
                let label = att.isImage ? "[图片]" : "[文件: \(att.filename)]"
                let text = msg.content.isEmpty ? label : "\(msg.content)\n\(label)"
                requestMessages.append(.init(role: msg.role.rawValue, content: .text(text)))
            } else {
                requestMessages.append(.init(role: msg.role.rawValue, content: .text(msg.content)))
            }
        }

        // 当前消息
        if let att = attachment {
            var parts: [ContentPart] = []
            if !content.isEmpty {
                parts.append(.textPart(content))
            }
            if att.isImage {
                // 图片：OpenAI Vision 格式
                let base64 = att.data.base64EncodedString()
                parts.append(.imagePart(base64: base64, mimeType: att.mimeType))
            } else {
                // 通用文件：自定义 file 格式
                let base64 = att.data.base64EncodedString()
                parts.append(.filePart(base64: base64, filename: att.filename, mimeType: att.mimeType))
            }
            requestMessages.append(.init(role: "user", content: .multimodal(parts)))
        } else {
            requestMessages.append(.init(role: "user", content: .text(content)))
        }

        return requestMessages
    }

    /// 构建 URLRequest
    private func buildURLRequest(
        messages: [ChatCompletionRequest.RequestMessage],
        stream: Bool,
        token: String
    ) throws -> URLRequest {
        guard let url = URL(string: baseURL) else {
            throw ChatError.invalidURL
        }

        let requestBody = ChatRequest(messages: messages, stream: stream)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 300  // 5 min for complex agent tasks

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)
        return request
    }

    /// 检查 HTTP 响应状态码
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

    // MARK: - Streaming (SSE) — primary mode

    /// 发送消息并以 SSE 流式接收 AI 回复
    ///
    /// 返回一个 AsyncThrowingStream，调用方逐个消费 StreamEvent：
    /// - `.thinking("正在分析图片...")` → 工具执行状态
    /// - `.content("文字...")` → 正常文本增量
    /// - `.done` → 流结束
    func sendMessageStream(
        _ content: String,
        attachment: Attachment? = nil,
        history: [Message]
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let token = await AuthService.shared.accessToken else {
            throw ChatError.notAuthenticated
        }

        let requestMessages = buildRequestMessages(content: content, attachment: attachment, history: history)
        let request = try buildURLRequest(messages: requestMessages, stream: true, token: token)

        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        try validateHTTPResponse(response)

        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in bytes.lines {
                        // SSE format: "data: {...}" or "data: [DONE]"
                        guard line.hasPrefix("data: ") else { continue }
                        let payload = String(line.dropFirst(6))

                        if payload == "[DONE]" {
                            continuation.yield(.done)
                            continuation.finish()
                            return
                        }

                        // Parse JSON chunk
                        guard let data = payload.data(using: .utf8) else { continue }
                        guard let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                            continue
                        }

                        guard let delta = chunk.choices?.first?.delta else { continue }

                        // Content safety filter (0-chunk empty response)
                        if delta.filtered == true, let text = delta.content {
                            continuation.yield(.filtered(text))
                            continue
                        }

                        // Thinking status (tool execution)
                        if let thinking = delta.thinking, !thinking.isEmpty {
                            continuation.yield(.thinking(thinking))
                        }

                        // Content text
                        if let text = delta.content, !text.isEmpty {
                            continuation.yield(.content(text))
                        }
                    }
                    // If stream ends without [DONE], still finish
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

    // MARK: - Session management

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
