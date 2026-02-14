import Foundation
import UIKit

/// AI 聊天 API 通信服务 – 通过 Orchestrator 代理到用户专属的 OpenClaw 实例
actor ChatService {
    static let shared = ChatService()

    private let baseURL = "https://prometheusclothing.net/api/v2/chat"

    /// 图片压缩：长边最大像素（确保 base64 后 < 800KB）
    private let maxImageDimension: CGFloat = 512
    /// 图片压缩：JPEG 质量
    private let jpegQuality: CGFloat = 0.4

    private init() {}

    /// 发送消息并获取 AI 回复（支持多模态）
    /// - Parameters:
    ///   - content: 用户消息文本
    ///   - imageData: 可选的图片数据（已压缩的 JPEG）
    ///   - history: 历史消息（用于上下文）
    /// - Returns: AI 回复文本
    func sendMessage(_ content: String, imageData: Data? = nil, history: [Message]) async throws -> String {
        guard let token = await AuthService.shared.accessToken else {
            throw ChatError.notAuthenticated
        }

        guard let url = URL(string: baseURL) else {
            throw ChatError.invalidURL
        }

        // 构建消息列表（最近 10 轮对话 = 20 条消息）
        // 历史消息中的图片不发送 base64（避免请求体过大），只用文本标记
        var requestMessages: [ChatCompletionRequest.RequestMessage] = []

        let recentHistory = history.suffix(20)
        for msg in recentHistory {
            if msg.imageData != nil {
                // 历史消息中曾有图片，用文本标记代替 base64
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

        let requestBody = ChatRequest(
            messages: requestMessages,
            stream: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            switch httpResponse.statusCode {
            case 401:
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

        guard let replyContent = completionResponse.choices?.first?.message?.content else {
            throw ChatError.emptyResponse
        }

        return replyContent
    }

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
