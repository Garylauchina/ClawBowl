import Foundation
import CryptoKit
import UIKit

/// WebSocket 事件类型（从 Gateway 接收）
enum StreamEvent {
    /// 工具执行状态（浅色字体显示）
    case thinking(String)
    /// 正常文本内容增量
    case content(String)
    /// 内容被安全审核过滤
    case filtered(String)
    /// Agent 生成的文件
    case file(FileInfo)
    /// 流结束
    case done
}

/// AI 聊天服务 – 通过 WebSocket 直连 OpenClaw Gateway
actor ChatService {
    static let shared = ChatService()

    private let apiBase = "http://106.55.174.74:8080"

    // MARK: - Gateway state (set by warmup)

    private var gatewayPath: String?
    private var gatewayWSURL: String?
    private var gatewayToken: String?
    private var sessionKey: String?
    private var devicePrivateKeyRaw: Data?
    private var devicePublicKeyB64: String?
    private var deviceId: String?

    // MARK: - WebSocket state

    private var wsTask: URLSessionWebSocketTask?
    private var receiveLoop: Task<Void, Never>?
    private var requestCallbacks: [String: CheckedContinuation<[String: Any], Error>] = [:]
    private var chatEventHandler: (([String: Any]) -> Void)?
    private var agentEventHandler: (([String: Any]) -> Void)?
    private var isConnected = false
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 5

    var isConfigured: Bool { gatewayPath != nil }

    private init() {}

    // MARK: - Configure

    func configure(
        gatewayURL: String,
        gatewayToken: String,
        sessionKey: String,
        devicePrivateKey: String,
        devicePublicKey: String,
        deviceId: String,
        gatewayWSURL: String? = nil
    ) {
        self.gatewayPath = gatewayURL
        self.gatewayWSURL = gatewayWSURL
        self.gatewayToken = gatewayToken
        self.sessionKey = sessionKey
        self.devicePrivateKeyRaw = Data(base64URLDecoded: devicePrivateKey)
        self.devicePublicKeyB64 = devicePublicKey
        self.deviceId = deviceId
    }

    // MARK: - WebSocket Connection

    func connect() async throws {
        guard let gwPath = gatewayPath else {
            throw ChatError.serviceUnavailable
        }

        let urlString: String
        if let directURL = gatewayWSURL {
            urlString = directURL
        } else {
            let wsBase = apiBase.replacingOccurrences(of: "https://", with: "wss://")
                .replacingOccurrences(of: "http://", with: "ws://")
            urlString = "\(wsBase)\(gwPath)/"
        }
        let wsURL = URL(string: urlString)!
        var request = URLRequest(url: wsURL)
        request.timeoutInterval = 30

        let session = URLSession(configuration: .default)
        let task = session.webSocketTask(with: request)
        self.wsTask = task
        task.resume()

        try await performHandshake(task)
        isConnected = true
        reconnectAttempts = 0

        startReceiveLoop()
    }

    func disconnect() {
        receiveLoop?.cancel()
        receiveLoop = nil
        wsTask?.cancel(with: .goingAway, reason: nil)
        wsTask = nil
        isConnected = false
        cancelAllPendingRequests(ChatError.serviceUnavailable)
    }

    func reconnectIfNeeded() async {
        guard isConfigured, !isConnected else { return }
        reconnectAttempts = 0
        print("[WS] reconnectIfNeeded: attempting reconnect")
        try? await connect()
    }

    // MARK: - Handshake

    private func performHandshake(_ task: URLSessionWebSocketTask) async throws {
        let challengeMsg = try await task.receive()
        guard case .string(let challengeStr) = challengeMsg,
              let challengeData = challengeStr.data(using: .utf8),
              let challenge = try? JSONSerialization.jsonObject(with: challengeData) as? [String: Any],
              let payload = challenge["payload"] as? [String: Any],
              let nonce = payload["nonce"] as? String else {
            throw ChatError.invalidResponse
        }

        guard let gwToken = gatewayToken,
              let privKeyData = devicePrivateKeyRaw,
              let pubKeyB64 = devicePublicKeyB64,
              let devId = deviceId else {
            throw ChatError.notAuthenticated
        }

        let signedAtMs = Int(Date().timeIntervalSince1970 * 1000)
        let scopes = ["operator.read", "operator.write"]
        let signPayload = [
            "v2", devId, "openclaw-ios", "cli", "operator",
            scopes.joined(separator: ","),
            String(signedAtMs), gwToken, nonce
        ].joined(separator: "|")

        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privKeyData)
        let signature = try privateKey.signature(for: Data(signPayload.utf8))
        let sigB64 = signature.base64URLEncodedString()

        let connectParams: [String: Any] = [
            "type": "req",
            "id": "connect",
            "method": "connect",
            "params": [
                "minProtocol": 3,
                "maxProtocol": 3,
                "client": [
                    "id": "openclaw-ios",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0",
                    "platform": "ios",
                    "mode": "cli"
                ],
                "role": "operator",
                "scopes": scopes,
                "auth": ["token": gwToken],
                "device": [
                    "id": devId,
                    "publicKey": pubKeyB64,
                    "signature": sigB64,
                    "signedAt": signedAtMs,
                    "nonce": nonce
                ]
            ] as [String: Any]
        ]

        let connectData = try JSONSerialization.data(withJSONObject: connectParams)
        try await task.send(.string(String(data: connectData, encoding: .utf8)!))

        let helloMsg = try await task.receive()
        guard case .string(let helloStr) = helloMsg,
              let helloData = helloStr.data(using: .utf8),
              let hello = try? JSONSerialization.jsonObject(with: helloData) as? [String: Any],
              hello["ok"] as? Bool == true else {
            throw ChatError.invalidResponse
        }
    }

    // MARK: - Receive Loop

    private func startReceiveLoop() {
        receiveLoop = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    guard let task = await self.wsTask else { break }
                    let message = try await task.receive()
                    guard case .string(let text) = message,
                          let data = text.data(using: .utf8),
                          let frame = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                        continue
                    }
                    await self.handleFrame(frame)
                } catch {
                    if !Task.isCancelled {
                        await self.handleDisconnect()
                    }
                    break
                }
            }
        }
    }

    private func handleFrame(_ frame: [String: Any]) {
        let type = frame["type"] as? String ?? ""

        switch type {
        case "res":
            if let id = frame["id"] as? String, let cont = requestCallbacks.removeValue(forKey: id) {
                if frame["ok"] as? Bool == true {
                    cont.resume(returning: frame["payload"] as? [String: Any] ?? [:])
                } else {
                    let errMsg = (frame["error"] as? [String: Any])?["message"] as? String ?? "Request failed"
                    cont.resume(throwing: ChatError.serverError)
                    _ = errMsg
                }
            }
        case "event":
            let event = frame["event"] as? String ?? ""
            let payload = frame["payload"] as? [String: Any] ?? [:]
            #if DEBUG
            let keys = Array(payload.keys).sorted()
            print("[WS] event: \(event), payload.keys: \(keys)")
            #endif
            if event == "chat" || event.hasPrefix("chat.") {
                chatEventHandler?(payload)
            } else if event == "agent" || event.hasPrefix("agent.") {
                agentEventHandler?(payload)
            } else if chatEventHandler != nil || agentEventHandler != nil {
                tryFallbackStreamPayload(event: event, payload: payload)
            }
        default:
            break
        }
    }

    private func handleDisconnect() {
        isConnected = false
        cancelAllPendingRequests(ChatError.serviceUnavailable)

        guard reconnectAttempts < maxReconnectAttempts else { return }
        reconnectAttempts += 1
        let delay = min(pow(2.0, Double(reconnectAttempts)), 30.0)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled, !isConnected else { return }
            try? await connect()
        }
    }

    private func cancelAllPendingRequests(_ error: Error) {
        for (_, cont) in requestCallbacks {
            cont.resume(throwing: error)
        }
        requestCallbacks.removeAll()
    }

    /// 未知 event 时尝试按通用流式 payload 解析并交给 chat/agent handler
    private func tryFallbackStreamPayload(event: String, payload: [String: Any]) {
        if let delta = payload["delta"] as? String, !delta.isEmpty, let agent = agentEventHandler {
            agent(["stream": "assistant", "data": ["delta": delta]])
            return
        }
        if let content = payload["content"] as? String, !content.isEmpty {
            if let chat = chatEventHandler {
                chat(["state": "delta", "message": ["content": content]])
            }
            if let agent = agentEventHandler, payload["stream"] == nil {
                agent(["stream": "assistant", "data": ["delta": content]])
            }
        }
    }

    // MARK: - Send Request

    private func sendRequest(method: String, params: [String: Any]) async throws -> [String: Any] {
        guard let task = wsTask, isConnected else {
            print("[WS] sendRequest(\(method)): wsTask=\(wsTask != nil) isConnected=\(isConnected) - BLOCKED")
            throw ChatError.serviceUnavailable
        }

        let id = UUID().uuidString
        print("[WS] sendRequest(\(method)): id=\(id)")
        let frame: [String: Any] = [
            "type": "req",
            "id": id,
            "method": method,
            "params": params
        ]

        let data = try JSONSerialization.data(withJSONObject: frame)
        try await task.send(.string(String(data: data, encoding: .utf8)!))

        return try await withCheckedThrowingContinuation { continuation in
            self.requestCallbacks[id] = continuation

            Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if let cont = self.requestCallbacks.removeValue(forKey: id) {
                    cont.resume(throwing: ChatError.serverError)
                }
            }
        }
    }

    // MARK: - Chat History

    func loadHistory() async throws -> [Message] {
        guard let sk = sessionKey else {
            print("[History] loadHistory: no sessionKey")
            throw ChatError.serviceUnavailable
        }

        print("[History] loadHistory: sessionKey=\(sk) isConnected=\(isConnected) wsTask=\(wsTask != nil)")
        let result = try await sendRequest(method: "chat.history", params: [
            "sessionKey": sk
        ])
        print("[History] loadHistory result keys: \(Array(result.keys))")

        guard let messages = result["messages"] as? [[String: Any]] else {
            print("[History] loadHistory: no 'messages' in result, result=\(result)")
            return []
        }
        print("[History] loadHistory: raw messages count=\(messages.count)")

        return messages.compactMap { msg -> Message? in
            guard let role = msg["role"] as? String,
                  let messageRole = Message.Role(rawValue: role) else { return nil }

            let content: String
            if let contentArray = msg["content"] as? [[String: Any]] {
                content = contentArray.compactMap { part -> String? in
                    guard part["type"] as? String == "text" else { return nil }
                    return part["text"] as? String
                }.joined()
            } else if let contentStr = msg["content"] as? String {
                content = contentStr
            } else {
                return nil
            }

            guard !content.isEmpty else { return nil }

            let timestamp: Date
            if let ts = msg["timestamp"] as? Double {
                timestamp = Date(timeIntervalSince1970: ts / 1000.0)
            } else if let ts = msg["timestamp"] as? Int {
                timestamp = Date(timeIntervalSince1970: Double(ts) / 1000.0)
            } else {
                timestamp = Date()
            }

            return Message(role: messageRole, content: content, timestamp: timestamp)
        }
    }

    // MARK: - Send Message (Streaming via WebSocket Events)

    private static func extractText(from msgContent: Any?) -> String {
        guard let msgContent = msgContent else { return "" }
        if let arr = msgContent as? [[String: Any]] {
            return arr.compactMap { p -> String? in
                guard p["type"] as? String == "text" else { return nil }
                return p["text"] as? String
            }.joined()
        }
        if let s = msgContent as? String { return s }
        return ""
    }

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

    func sendMessageStream(
        _ content: String,
        attachment: Attachment? = nil,
        history: [Message]
    ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let sk = sessionKey, isConnected else {
            throw ChatError.serviceUnavailable
        }

        var uploadedPath: String?
        if let att = attachment, !att.isImage || att.data.count > 10 * 1024 * 1024 {
            uploadedPath = try await uploadAttachment(att)
        }

        var messageText = content
        if let att = attachment, att.isImage, att.data.count <= 10 * 1024 * 1024 {
            let b64 = att.data.base64EncodedString()
            messageText = content.isEmpty ? "请分析这张图片\n\n[image:data:\(att.mimeType);base64,\(b64)]" : "\(content)\n\n[image:data:\(att.mimeType);base64,\(b64)]"
        } else if let path = uploadedPath {
            messageText = "[用户发送了文件: \(path)]" + (content.isEmpty ? "" : "\n\n\(content)")
        }

        let idempotencyKey = UUID().uuidString

        return AsyncThrowingStream { continuation in
            let sendTask = Task { [weak self] in
                guard let self else { return }

                var seenTools = Set<String>()
                var thinkingEmitted = false
                var finalReceived = false
                /// 流式合并器：累积 delta，每 50ms flush 一次，避免 token 级 yield
                var streamContentBuffer = ""
                let streamBufferLock = NSLock()
                let flushIntervalNs: UInt64 = 50_000_000 // 50ms
                var flushTask: Task<Void, Never>?

                func flushStreamBuffer() {
                    streamBufferLock.lock()
                    let chunk = streamContentBuffer
                    streamContentBuffer = ""
                    streamBufferLock.unlock()
                    if !chunk.isEmpty { continuation.yield(.content(chunk)) }
                }

                func appendStreamBuffer(_ s: String) {
                    streamBufferLock.lock()
                    streamContentBuffer += s
                    streamBufferLock.unlock()
                }

                func startFlushTimer() {
                    guard flushTask == nil else { return }
                    flushTask = Task {
                        while !Task.isCancelled {
                            try? await Task.sleep(nanoseconds: flushIntervalNs)
                            guard !Task.isCancelled else { break }
                            flushStreamBuffer()
                        }
                    }
                }

                await self.setChatEventHandler { payload in
                    let state = payload["state"] as? String ?? ""
                    let message = payload["message"] as? [String: Any] ?? [:]

                    if state == "delta" || state == "final" || state.isEmpty {
                        var text = Self.extractText(from: message["content"])
                        if text.isEmpty, let top = payload["content"] as? String { text = top }
                        if text.isEmpty, let top = payload["delta"] as? String { text = top }

                        if !text.isEmpty {
                            appendStreamBuffer(text)
                            startFlushTimer()
                        }
                        if state == "final" {
                            flushTask?.cancel()
                            flushTask = nil
                            flushStreamBuffer()
                            continuation.yield(.done)
                            continuation.finish()
                            finalReceived = true
                        }
                    }
                }

                await self.setAgentEventHandler { payload in
                    let stream = payload["stream"] as? String ?? ""
                    var data = payload["data"] as? [String: Any] ?? [:]
                    if data.isEmpty, payload["delta"] != nil || payload["content"] != nil {
                        data = ["delta": payload["delta"] ?? payload["content"] ?? ""]
                    }

                    switch stream {
                    case "assistant", "":
                        let delta = (data["delta"] as? String) ?? (data["content"] as? String) ?? ""
                        if !delta.isEmpty {
                            appendStreamBuffer(delta)
                            startFlushTimer()
                            thinkingEmitted = true
                        }
                    case "tool":
                        if let name = data["name"] as? String, !name.isEmpty, !seenTools.contains(name) {
                            seenTools.insert(name)
                            let status = Self.toolStatusMap[name] ?? "正在执行 \(name)..."
                            let prefix = thinkingEmitted ? "\n" : ""
                            continuation.yield(.thinking(prefix + status + "\n"))
                            thinkingEmitted = true
                        }
                    case "lifecycle":
                        let phase = data["phase"] as? String ?? ""
                        if phase == "end" && !finalReceived {
                            flushTask?.cancel()
                            flushTask = nil
                            flushStreamBuffer()
                            continuation.yield(.done)
                            continuation.finish()
                        }
                    default:
                        break
                    }
                }

                do {
                    let _ = try await self.sendRequest(method: "chat.send", params: [
                        "sessionKey": sk,
                        "message": messageText,
                        "deliver": true,
                        "idempotencyKey": idempotencyKey
                    ])
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                sendTask.cancel()
                Task { [weak self] in
                    await self?.setChatEventHandler(nil)
                    await self?.setAgentEventHandler(nil)
                }
            }
        }
    }

    private func setChatEventHandler(_ handler: (([String: Any]) -> Void)?) {
        chatEventHandler = handler
    }

    private func setAgentEventHandler(_ handler: (([String: Any]) -> Void)?) {
        agentEventHandler = handler
    }

    // MARK: - Cancel Chat

    func cancelChat() async {
        guard let sk = sessionKey, isConnected else { return }
        _ = try? await sendRequest(method: "chat.abort", params: ["sessionKey": sk])
    }

    // MARK: - Upload Attachment (HTTP)

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

    // MARK: - Session Management

    func resetSession() async {
        disconnect()

        guard let token = await AuthService.shared.accessToken else { return }
        guard let url = URL(string: "\(apiBase)/api/v2/instance/clear") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        _ = try? await URLSession.shared.data(for: request)

        gatewayPath = nil
        gatewayToken = nil
        sessionKey = nil
        devicePrivateKeyRaw = nil
        devicePublicKeyB64 = nil
        deviceId = nil
    }

    // MARK: - HTTP Validation

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw ChatError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            switch httpResponse.statusCode {
            case 401:
                Task { try? await AuthService.shared.refreshToken() }
                throw ChatError.notAuthenticated
            case 429: throw ChatError.rateLimited
            case 500: throw ChatError.serverError
            case 502, 503: throw ChatError.serviceUnavailable
            default: throw ChatError.httpError(httpResponse.statusCode)
            }
        }
    }
}

// MARK: - Base64URL Helpers

extension Data {
    init?(base64URLDecoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        self.init(base64Encoded: base64)
    }

    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Chat Errors

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
        case .invalidURL: return "无效的请求地址"
        case .invalidResponse: return "服务器响应异常"
        case .emptyResponse: return "AI 未返回内容"
        case .rateLimited: return "请求过于频繁，请稍后再试"
        case .serverError: return "服务器内部错误"
        case .serviceUnavailable: return "AI 服务正在启动，请稍后重试"
        case .notAuthenticated: return "请先登录"
        case .uploadFailed: return "附件上传失败，请重试"
        case .httpError(let code): return "请求失败 (\(code))"
        }
    }
}

