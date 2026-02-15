import Foundation
import UIKit

/// SSE 流式事件类型
enum StreamEvent {
    /// 工具执行状态（浅色字体显示）
    case thinking(String)
    /// 正常文本内容增量
    case content(String)
    /// 流结束
    case done
}

/// AI 聊天 API 通信服务 – 通过 Orchestrator 代理到用户专属的 OpenClaw 实例
actor ChatService {
    static let shared = ChatService()

    private let baseURL = "https://prometheusclothing.net/api/v2/chat"

    /// 图片压缩：长边最大像素（确保 base64 后 < 800KB）
    private let maxImageDimension: CGFloat = 512
    /// 图片压缩：JPEG 质量
    private let jpegQuality: CGFloat = 0.4

    private init() {}

    // MARK: - Build request messages (shared by both modes)

    /// 构建 API 请求消息列表
    private func buildRequestMessages(
        content: String,
        imageData: Data?,
        history: [Message]
    ) -> [ChatCompletionRequest.RequestMessage] {
        var requestMessages: [ChatCompletionRequest.RequestMessage] = []

        // 历史消息（最近 20 条），图片用文本标记代替
        let recentHistory = history.suffix(20)
        for msg in recentHistory {
            if msg.imageData != nil {
                let text = msg.content.isEmpty ? "[图片]" : "\(msg.content)\n[图片]"
                requestMessages.append(.init(role: msg.role.rawValue, content: .text(text)))
            } else {
                requestMessages.append(.init(role: msg.role.rawValue, content: .text(msg.content)))
            }
        }

        // 当前消息
        if let imgData = imageData {
            let base64 = imgData.base64EncodedString()
            var parts: [ContentPart] = []
            if !content.isEmpty {
                parts.append(.textPart(content))
            }
            parts.append(.imagePart(base64: base64))
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

    // MARK: - Non-streaming (legacy, kept as fallback)

    /// 发送消息并获取 AI 回复（非流式，一次性返回）
    func sendMessage(_ content: String, imageData: Data? = nil, history: [Message]) async throws -> String {
        guard let token = await AuthService.shared.accessToken else {
            throw ChatError.notAuthenticated
        }

        let requestMessages = buildRequestMessages(content: content, imageData: imageData, history: history)
        let request = try buildURLRequest(messages: requestMessages, stream: false, token: token)

        let (data, response) = try await URLSession.shared.data(for: request)
        try validateHTTPResponse(response)

        let decoder = JSONDecoder()
        let completionResponse = try decoder.decode(ChatCompletionResponse.self, from: data)

        guard let replyContent = completionResponse.choices?.first?.message?.content else {
            throw ChatError.emptyResponse
        }
        return replyContent
    }

    // MARK: - Streaming (SSE)

    /// 发送消息并以 SSE 流式接收 AI 回复
    ///
    /// 返回一个 AsyncThrowingStream，调用方逐个消费 StreamEvent：
    /// - `.thinking("正在分析图片...")` → 工具执行状态
    /// - `.content("文字...")` → 正常文本增量
    /// - `.done` → 流结束
    func sendMessageStream(
        _ content: String,
        imageData: Data? = nil,
        history: [Message]
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let token = await AuthService.shared.accessToken else {
            throw ChatError.notAuthenticated
        }

        let requestMessages = buildRequestMessages(content: content, imageData: imageData, history: history)
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

    // MARK: - Image compression

    /// 压缩图片：缩放到最大尺寸并转为 JPEG
    func compressImage(_ image: UIImage) -> Data? {
        let maxDim = maxImageDimension
        var targetSize = image.size

        // 等比缩放
        if max(targetSize.width, targetSize.height) > maxDim {
            let scale = maxDim / max(targetSize.width, targetSize.height)
            targetSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
        }

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: jpegQuality)
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
