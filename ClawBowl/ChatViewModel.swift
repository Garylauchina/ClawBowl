import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var filteredNotice: String?
    @Published var scrollTrigger: UInt = 0
    /// 流式跟随：仅在 isAtBottom 时低频滚到底，与 scrollTrigger 分离
    @Published var followTrigger: UInt = 0
    /// 上滑加载更多时保持滚动位置（Telegram 式）
    @Published var scrollAnchorAfterPrepend: String?
    @Published var loadingOlder = false
    @Published var hasMoreHistory = false

    private var oldestLoadedTimestampMs: Int?
    /// 是否已收到过首屏历史（用于区分首次加载 vs 前台/ready 刷新：首次替换，刷新合并）
    private var hasReceivedFirstPage = false
    private var activeStreamTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var pendingReadyID: UUID?

    // MARK: - Stream Throttle

    private var streamingIdx: Int?
    private var pendingContent = ""
    private var pendingThinking = ""
    private var throttleTask: Task<Void, Never>?
    private static let throttleInterval: UInt64 = 100_000_000 // 100ms
    private var thinkingTrimCounter: Int = 0

    // MARK: - Scroll Throttle（禁止 token 级滚动）

    private var lastScrollKick: CFTimeInterval = 0
    private let scrollKickMinInterval: CFTimeInterval = 0.30

    private func kickScrollThrottled() {
        let now = CACurrentMediaTime()
        guard now - lastScrollKick >= scrollKickMinInterval else { return }
        lastScrollKick = now
        scrollTrigger &+= 1
    }

    private var lastFollowKick: CFTimeInterval = 0
    private let followMinInterval: CFTimeInterval = 0.15

    private func kickFollowThrottled() {
        let now = CACurrentMediaTime()
        guard now - lastFollowKick >= followMinInterval else { return }
        lastFollowKick = now
        followTrigger &+= 1
    }

    // MARK: - Lifecycle

    private var readyObserver: Any?
    private var foregroundObserver: Any?

    init() {
        if let saved = MessageStore.load(), !saved.isEmpty {
            messages = saved
        } else {
            messages = [Message(role: .assistant, content: "你好！我是 AI 助手，有什么可以帮你的吗？")]
        }

        Task { await loadHistoryViaHTTP() }

        readyObserver = NotificationCenter.default.addObserver(
            forName: .chatServiceReady, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in await self.loadHistoryViaHTTP() }
        }

        foregroundObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                await ChatService.shared.reconnectIfNeeded()
                try? await Task.sleep(nanoseconds: 500_000_000)
                await self.loadHistoryViaHTTP()
            }
        }
    }

    deinit {
        if let obs = readyObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver { NotificationCenter.default.removeObserver(obs) }
    }

    private static let historyURL = "http://106.55.174.74:8080/api/v2/chat/history"
    private static let historyPageSize = 100

    /// 首屏/刷新：拉取最新一页历史（不传 before）
    private func loadHistoryViaHTTP() async {
        guard let token = AuthService.shared.accessToken,
              let url = URL(string: Self.historyURL) else {
            print("[History] no token or bad URL")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let body: [String: Any] = ["limit": Self.historyPageSize]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            print("[History] HTTP \(statusCode), bytes=\(data.count)")
            guard statusCode == 200 else { return }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawMessages = json["messages"] as? [[String: Any]] else {
                print("[History] bad JSON structure")
                return
            }

            let history = Self.parseHistoryChunk(rawMessages)
            let hasMore = (json["hasMore"] as? Bool) ?? false
            let oldestTs = json["oldestTimestamp"] as? Int

            print("[History] parsed \(history.count) messages, hasMore=\(hasMore)")
            
            // Telegram 式：首次首屏以服务端为准并替换本地/占位；后续刷新（前台/ready）只合并新消息
            if history.isEmpty {
                if !hasReceivedFirstPage {
                    messages = []
                    MessageStore.saveRecent([], maxCount: 0)
                }
                hasMoreHistory = false
                oldestLoadedTimestampMs = nil
                hasReceivedFirstPage = true
                return
            }
            if !hasReceivedFirstPage {
                messages = history
            } else {
                let existingIds = Set(messages.compactMap { $0.serverId })
                let newMessages = history.filter { !existingIds.contains($0.serverId ?? "") }
                if !newMessages.isEmpty {
                    messages.append(contentsOf: newMessages)
                    messages.sort { $0.timestamp < $1.timestamp }
                }
            }
            hasReceivedFirstPage = true
            hasMoreHistory = hasMore
            oldestLoadedTimestampMs = oldestTs
            MessageStore.saveRecent(messages, maxCount: Self.historyPageSize * 5)
        } catch {
            print("[History] HTTP loadHistory failed: \(error)")
        }
    }

    /// 下拉刷新：重新拉取首屏并合并（与 Telegram 下拉刷新一致）
    func refreshHistoryFromServer() async {
        await loadHistoryViaHTTP()
    }

    /// 上滑加载更早的历史（分页，保持滚动位置）
    func loadOlderMessagesIfNeeded() async {
        guard hasMoreHistory, !loadingOlder,
              let before = oldestLoadedTimestampMs else { return }
        guard AuthService.shared.accessToken != nil,
              let url = URL(string: Self.historyURL) else { return }

        loadingOlder = true
        let anchorListId = messages.first?.listId

        defer { loadingOlder = false }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(AuthService.shared.accessToken!)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        let body: [String: Any] = ["limit": Self.historyPageSize, "before": before]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let rawMessages = json["messages"] as? [[String: Any]] else { return }

            let older = Self.parseHistoryChunk(rawMessages)
            let hasMore = (json["hasMore"] as? Bool) ?? false
            let newOldest = json["oldestTimestamp"] as? Int

            if older.isEmpty { return }

            hasMoreHistory = hasMore
            oldestLoadedTimestampMs = newOldest
            scrollAnchorAfterPrepend = anchorListId
            messages.insert(contentsOf: older, at: 0)
            MessageStore.saveRecent(messages, maxCount: Self.historyPageSize * 5)
            print("[History] prepended \(older.count) older, hasMore=\(hasMore)")
        } catch {
            print("[History] loadOlder failed: \(error)")
        }
    }

    private static func parseHistoryChunk(_ raw: [[String: Any]]) -> [Message] {
        raw.compactMap { dict in
            guard let roleStr = dict["role"] as? String,
                  let content = dict["content"] as? String,
                  !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return nil
            }
            let role: Message.Role = roleStr == "user" ? .user : .assistant
            let serverId = dict["id"] as? String
            let timestamp: Date
            if let ts = dict["timestamp"] as? Double {
                timestamp = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000.0 : ts)
            } else if let ts = dict["timestamp"] as? Int {
                timestamp = Date(timeIntervalSince1970: Double(ts) / 1000.0)
            } else if let ts = dict["timestamp"] as? String {
                if let ms = Double(ts) {
                    timestamp = Date(timeIntervalSince1970: ms > 1e12 ? ms / 1000.0 : ms)
                } else if let d = ISO8601DateFormatter().date(from: ts) ?? ISO8601DateFormatter().date(from: ts + "Z") {
                    timestamp = d
                } else {
                    timestamp = Date()
                }
            } else {
                timestamp = Date()
            }
            return Message(serverId: serverId, role: role, content: content, timestamp: timestamp)
        }
    }

    // MARK: - Ready Gate

    func onMessageAppear(_ id: UUID) {
        if id == pendingReadyID {
            pendingReadyID = nil
            readyContinuation?.resume()
            readyContinuation = nil
        }
    }

    // MARK: - Send Message

    func sendMessage(content rawContent: String, attachment: Attachment?, replyTo: Message? = nil) {
        let content = rawContent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty || attachment != nil else { return }
        guard !isLoading else { return }

        isLoading = true

        activeStreamTask = Task { [weak self] in
            guard let self else { return }
            do {
                var displayText: String
                if content.isEmpty {
                    if let att = attachment {
                        displayText = att.isImage ? "[图片]" : "[文件: \(att.filename)]"
                    } else {
                        displayText = ""
                    }
                } else {
                    displayText = content
                }

                // Prepend quote block for reply-to
                var actualContent = content
                if let reply = replyTo {
                    let quoteLine = reply.content.isEmpty ? "[附件]" : reply.quotePreview
                    let prefix = "> \(reply.role == .user ? "我" : "AI"): \(quoteLine)\n\n"
                    actualContent = prefix + content
                    if displayText == content {
                        displayText = prefix + displayText
                    }
                }

                let userMessage = Message(role: .user, content: displayText, attachment: attachment)
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.messages.append(userMessage)
                }

                let placeholderMessage = Message(role: .assistant, content: "", isStreaming: true)
                let placeholderID = placeholderMessage.id

                self.pendingReadyID = placeholderID
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.messages.append(placeholderMessage)
                }

                self.streamingIdx = self.messages.count - 1

                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if self.pendingReadyID == nil {
                        cont.resume()
                    } else {
                        self.readyContinuation = cont
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard self.readyContinuation != nil else { return }
                            self.readyContinuation?.resume()
                            self.readyContinuation = nil
                            self.pendingReadyID = nil
                        }
                    }
                }

                let historyMessages = Array(self.messages.dropLast(2).suffix(30))

                let stream = try await ChatService.shared.sendMessageStream(
                    actualContent,
                    attachment: attachment,
                    history: historyMessages
                )

                var wasFiltered = false
                for try await event in stream {
                    guard let idx = streamingIdx, idx < messages.count,
                          messages[idx].id == placeholderID else { continue }

                    switch event {
                    case .thinking(let status):
                        pendingThinking += status
                        scheduleThrottledFlush(idx: idx)
                    case .content(let text):
                        let toAppend = Self.dedupeStreamChunk(chunk: text, current: messages[idx].content, pending: pendingContent)
                        if !messages[idx].thinkingText.isEmpty || !pendingThinking.isEmpty {
                            flushThrottleNow(idx: idx)
                            messages[idx].thinkingText = ""
                            if !toAppend.isEmpty { pendingContent += toAppend; scheduleThrottledFlush(idx: idx) }
                        } else {
                            if !toAppend.isEmpty { pendingContent += toAppend; scheduleThrottledFlush(idx: idx) }
                        }
                    case .file(let fileInfo):
                        flushThrottleNow(idx: idx)
                        messages[idx].files.append(fileInfo)
                        kickScrollThrottled()
                    case .filtered(let text):
                        flushThrottleNow(idx: idx)
                        messages[idx].content = text
                        messages[idx].thinkingText = ""
                        messages[idx].status = .filtered
                        messages[idx].isStreaming = false
                        wasFiltered = true
                    case .done:
                        flushThrottleNow(idx: idx)
                        messages[idx].isStreaming = false
                        if !messages[idx].content.isEmpty {
                            messages[idx].thinkingText = ""
                        }
                    }
                }

                // Stream ended
                flushThrottleNow(idx: streamingIdx)
                if wasFiltered {
                    let removeCount = min(self.messages.count, 4)
                    self.messages.removeLast(removeCount)
                    MessageStore.saveRecent(self.messages, maxCount: Self.historyPageSize * 5)
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.filteredNotice = "检测到内容限制，已自动清理相关对话，请继续"
                    }
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 4_000_000_000)
                        withAnimation(.easeInOut(duration: 0.5)) {
                            self.filteredNotice = nil
                        }
                    }
                } else {
                    if let idx = streamingIdx, idx < messages.count,
                       messages[idx].id == placeholderID {
                        messages[idx].isStreaming = false
                        if !messages[idx].content.isEmpty {
                            messages[idx].thinkingText = ""
                        }
                        if messages[idx].content.isEmpty && messages[idx].thinkingText.isEmpty {
                            messages[idx].content = "AI 未返回内容，请重试。"
                            messages[idx].status = .error
                        }
                    }
                    MessageStore.saveRecent(messages, maxCount: Self.historyPageSize * 5)
                }
                isLoading = false
                streamingIdx = nil
            } catch {
                flushThrottleNow(idx: streamingIdx)
                let friendlyMsg = Self.friendlyErrorMessage(for: error)
                if let lastIdx = messages.indices.last,
                   messages[lastIdx].role == .assistant && messages[lastIdx].isStreaming {
                    messages[lastIdx].content = friendlyMsg
                    messages[lastIdx].status = .error
                    messages[lastIdx].isStreaming = false
                    messages[lastIdx].thinkingText = ""
                } else {
                    let errorMessage = Message(role: .assistant, content: friendlyMsg, status: .error)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.messages.append(errorMessage)
                    }
                }
                isLoading = false
                streamingIdx = nil
                MessageStore.saveRecent(messages, maxCount: Self.historyPageSize * 5)
            }
        }
    }

    // MARK: - Stream Throttle Internals

    /// snapshot/delta 去重：后端发累计快照或重复帧时只追加差量或忽略
    private static func dedupeStreamChunk(chunk: String, current: String, pending: String) -> String {
        let existing = current + pending
        if chunk.count > existing.count, chunk.hasPrefix(existing) {
            return String(chunk.dropFirst(existing.count))
        }
        if chunk == existing || existing.hasSuffix(chunk) {
            return ""
        }
        return chunk
    }

    private func scheduleThrottledFlush(idx: Int) {
        guard throttleTask == nil else { return }
        throttleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.throttleInterval)
            guard let self else { return }
            self.flushThrottleNow(idx: self.streamingIdx ?? idx)
        }
    }

    private func flushThrottleNow(idx: Int?) {
        throttleTask?.cancel()
        throttleTask = nil
        guard let idx, idx < messages.count else { return }

        var appendedContent = false
        if !pendingContent.isEmpty {
            messages[idx].content += pendingContent
            pendingContent = ""
            appendedContent = true
        }
        if !pendingThinking.isEmpty {
            messages[idx].thinkingText += pendingThinking
            thinkingTrimCounter += 1
            if thinkingTrimCounter % 8 == 0, messages[idx].thinkingText.count > 1000 {
                let text = messages[idx].thinkingText
                let start = text.index(text.endIndex, offsetBy: -800)
                messages[idx].thinkingText = "…" + String(text[start...])
            }
            pendingThinking = ""
        }
        if appendedContent {
            kickScrollThrottled()
            if streamingIdx != nil {
                kickFollowThrottled()
            }
        }
    }

    // MARK: - Cancel Stream

    func cancelStream() {
        activeStreamTask?.cancel()
        activeStreamTask = nil
        flushThrottleNow(idx: streamingIdx)

        if let lastIdx = messages.indices.last,
           messages[lastIdx].role == .assistant && messages[lastIdx].isStreaming {
            messages[lastIdx].isStreaming = false
            if messages[lastIdx].content.isEmpty && !messages[lastIdx].thinkingText.isEmpty {
                messages[lastIdx].content = messages[lastIdx].thinkingText
                messages[lastIdx].thinkingText = ""
            }
            if !messages[lastIdx].content.isEmpty {
                messages[lastIdx].content += "\n\n[已中断]"
            } else {
                messages[lastIdx].content = "[已中断]"
            }
            MessageStore.saveRecent(messages, maxCount: Self.historyPageSize * 5)
        }

        isLoading = false
        streamingIdx = nil
        Task { await ChatService.shared.cancelChat() }
    }

    // MARK: - Clear Chat

    func clearChat() {
        withAnimation {
            messages = [
                Message(role: .assistant, content: "聊天记录已清空。有什么可以帮你的吗？")
            ]
        }
        MessageStore.clear()
        Task { await ChatService.shared.resetSession() }
    }

    // MARK: - Error Helpers

    private static func friendlyErrorMessage(for error: Error) -> String {
        if let chatError = error as? ChatError {
            return chatError.localizedDescription
        }
        let desc = error.localizedDescription.lowercased()
        if desc.contains("network") || desc.contains("internet") || desc.contains("offline")
            || desc.contains("not connected") {
            return "网络连接异常，请检查网络后重试"
        }
        if desc.contains("timed out") || desc.contains("timeout") {
            return "请求超时，AI 可能正在处理复杂任务，请稍后重试"
        }
        if desc.contains("ssl") || desc.contains("certificate") || desc.contains("trust") {
            return "安全连接异常，请稍后重试"
        }
        if desc.contains("cancel") {
            return "请求已取消"
        }
        return "服务暂时不可用，请稍后重试"
    }
}
