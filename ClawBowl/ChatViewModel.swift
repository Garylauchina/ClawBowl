import Foundation
import SwiftUI

@MainActor
final class ChatViewModel: ObservableObject {
    @Published var messages: [Message] = []
    @Published var isLoading = false
    @Published var filteredNotice: String?
    @Published var scrollTrigger: UInt = 0

    private var activeStreamTask: Task<Void, Never>?
    private var readyContinuation: CheckedContinuation<Void, Never>?
    private var pendingReadyID: UUID?

    // MARK: - Stream Throttle

    private var streamingIdx: Int?
    private var pendingContent = ""
    private var pendingThinking = ""
    private var throttleTask: Task<Void, Never>?
    private static let throttleInterval: UInt64 = 100_000_000 // 100ms

    // MARK: - Lifecycle

    init() {
        if let saved = MessageStore.load(), !saved.isEmpty {
            messages = saved
        } else {
            messages = [Message(role: .assistant, content: "你好！我是 AI 助手，有什么可以帮你的吗？")]
        }
    }

    // MARK: - Session History Sync (from backend chat_logs)

    /// Sync with backend chat_logs to recover historical messages.
    /// Called on view appear. If local is empty, loads full history from server.
    func syncSessionHistory() {
        Task { [weak self] in
            guard let self else { return }
            do {
                let remote = try await ChatService.shared.fetchSessionHistory(limit: 200)
                guard !remote.isEmpty else { return }

                if self.messages.isEmpty || (self.messages.count == 1 && self.messages.first?.role == .assistant) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.messages = remote.sorted { $0.timestamp < $1.timestamp }
                    }
                    MessageStore.save(self.messages)
                    self.scrollTrigger &+= 1
                    return
                }

                let localTimestamps = self.messages.map { $0.timestamp.timeIntervalSince1970 }

                var newMessages: [Message] = []
                for msg in remote {
                    let ts = msg.timestamp.timeIntervalSince1970
                    let isDuplicate = localTimestamps.contains(where: { abs($0 - ts) < 2 })
                    if !isDuplicate {
                        newMessages.append(msg)
                    }
                }

                if !newMessages.isEmpty {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        self.messages.append(contentsOf: newMessages)
                        self.messages.sort { $0.timestamp < $1.timestamp }
                    }
                    MessageStore.save(self.messages)
                    self.scrollTrigger &+= 1
                }
            } catch {
                print("[HistorySync] failed: \(error)")
            }
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

                let historyMessages = Array(self.messages.dropLast(2))

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
                        if !messages[idx].thinkingText.isEmpty || !pendingThinking.isEmpty {
                            flushThrottleNow(idx: idx)
                            messages[idx].thinkingText = ""
                            messages[idx].content = text
                        } else {
                            pendingContent += text
                            scheduleThrottledFlush(idx: idx)
                        }
                    case .file(let fileInfo):
                        flushThrottleNow(idx: idx)
                        messages[idx].files.append(fileInfo)
                        scrollTrigger &+= 1
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
                    MessageStore.save(self.messages)
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
                    MessageStore.save(messages)
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
                MessageStore.save(messages)
            }
        }
    }

    // MARK: - Stream Throttle Internals

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

        if !pendingContent.isEmpty {
            messages[idx].content += pendingContent
            pendingContent = ""
            scrollTrigger &+= 1
        }
        if !pendingThinking.isEmpty {
            messages[idx].thinkingText += pendingThinking
            if messages[idx].thinkingText.count > 1000 {
                let text = messages[idx].thinkingText
                let start = text.index(text.endIndex, offsetBy: -800)
                messages[idx].thinkingText = "…" + String(text[start...])
            }
            pendingThinking = ""
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
            MessageStore.save(messages)
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
