import Foundation
import SwiftUI

/// 单会话聊天 ViewModel：驱动 UI 模型 + 跟随状态，事件经 GatewayEventReducer 收敛后应用
@MainActor
final class ChatScreenViewModel: ObservableObject {
    let sessionKey: String

    @Published var messages: [Message] = []
    @Published var isStreaming = false
    @Published var isFollowing = true
    @Published var streamError: String?  // 如 "回复可能不完整"
    /// 内容 flush 后递增，用于驱动跟随滚动（替代 messages.count）
    @Published var followTick: UInt = 0

    private let reducer: GatewayEventReducer
    private var contentThrottleBuffer = ""
    private var contentFlushTask: Task<Void, Never>?
    private let throttleIntervalMs = 150

    init(sessionKey: String) {
        self.sessionKey = sessionKey
        self.reducer = GatewayEventReducer(currentSessionKey: sessionKey)
    }

    /// 进入聊天页：设为当前会话、注册事件与断线回调、加载历史
    func onAppear() {
        streamError = nil
        Task {
            await ChatService.shared.setCurrentSessionKey(sessionKey)
            await ChatService.shared.setEventSink(sink: { [weak self] event, payload in
                await self?.handleEvent(event: event, payload: payload)
            }, onDisconnect: { [weak self] in
                await self?.handleDisconnect()
            })
            await reducer.resetRun()
            await loadHistory()
        }
    }

    /// 离开聊天页：先取消注册（避免旧 UI 再收事件），再 abort 后端
    func onDisappear() {
        contentFlushTask?.cancel()
        contentFlushTask = nil
        Task {
            await ChatService.shared.setEventSink(sink: nil, onDisconnect: nil)
            if isStreaming {
                await ChatService.shared.cancelChat()
            }
        }
    }

    /// 加载该会话历史：先本地缓存，再优先服务端
    func loadHistory() async {
        let cached = SessionStore.load(sessionKey: sessionKey)
        await MainActor.run { if !(cached?.isEmpty ?? true) { messages = cached ?? [] } }
        guard await ChatService.shared.effectiveSessionKey == sessionKey else { return }
        if let server = try? await ChatService.shared.loadHistory(), !server.isEmpty {
            await MainActor.run { messages = server }
        }
    }

    /// 发送消息：先追加用户 + 占位 assistant，再 chat.send；正文由 reducer 增量更新
    func sendMessage(content: String, attachment: Attachment?) async {
        let effective = await ChatService.shared.effectiveSessionKey
        guard effective == sessionKey else {
            await MainActor.run { streamError = "会话已切换，请重试" }
            return
        }
        var messageText = content
        if let att = attachment {
            if att.isImage, att.data.count <= 10 * 1024 * 1024 {
                let b64 = att.data.base64EncodedString()
                messageText = content.isEmpty ? "请分析这张图片\n\n[image:data:\(att.mimeType);base64,\(b64)]" : "\(content)\n\n[image:data:\(att.mimeType);base64,\(b64)]"
            } else {
                guard let path = try? await ChatService.shared.uploadAttachment(att) else { return }
                messageText = "[用户发送了文件: \(path)]" + (content.isEmpty ? "" : "\n\n\(content)")
            }
        }
        let idempotencyKey = UUID().uuidString

        let userMsg = Message(role: .user, content: content, attachment: attachment, status: .sent)
        let placeholderAssistant = Message(role: .assistant, content: "", status: .sent, isStreaming: true)
        messages.append(userMsg)
        messages.append(placeholderAssistant)
        isStreaming = true
        streamError = nil
        await reducer.resetRun()

        do {
            try await ChatService.shared.sendMessageOnly(sessionKey: sessionKey, messageText: messageText, idempotencyKey: idempotencyKey)
        } catch {
            isStreaming = false
            if let last = messages.last, last.role == .assistant, last.content.isEmpty {
                messages[messages.count - 1] = Message(role: .assistant, content: "", status: .error)
            }
            streamError = "发送失败"
        }
    }

    /// 停止当前流
    func stopStreaming() {
        Task {
            await ChatService.shared.cancelChat()
        }
    }

    /// 一键到底：置为跟随并触发滚底（由 View 监听 isFollowing 或单独触发）
    func scrollToBottom() {
        isFollowing = true
    }

    // MARK: - 事件处理（reducer 输出应用）

    private func handleEvent(event: String, payload: [String: Any]) async {
        let actions = await reducer.reduce(event: event, payload: payload)
        await MainActor.run { [weak self] in
            self?.apply(actions)
        }
    }

    private func handleDisconnect() async {
        let actions = await reducer.disconnect()
        await MainActor.run { [weak self] in
            self?.contentFlushTask?.cancel()
            self?.contentFlushTask = nil
            self?.flushContentThrottle()
            self?.apply(actions)
        }
    }

    private func apply(_ actions: [GatewayUIAction]) {
        for a in actions {
            switch a {
            case .appendUser(let text, _):
                messages.append(Message(role: .user, content: text))
            case .updateAssistantContent(let delta):
                contentThrottleBuffer += delta
                scheduleContentFlush()
            case .updateAssistantThinking(let text):
                flushContentThrottle()
                if let last = messages.last, last.role == .assistant {
                    let cur = messages[messages.count - 1]
                    let newThinking = cur.thinkingText.isEmpty ? text : cur.thinkingText + "\n" + text
                    messages[messages.count - 1] = Message(
                        id: cur.id, serverId: cur.serverId, role: .assistant,
                        content: cur.content, attachment: cur.attachment, timestamp: cur.timestamp,
                        status: cur.status, thinkingText: newThinking, isStreaming: cur.isStreaming,
                        files: cur.files, eventId: cur.eventId
                    )
                }
            case .appendAssistantFile(let name, let path, let size, let mimeType, let inlineData):
                flushContentThrottle()
                if let last = messages.last, last.role == .assistant {
                    let cur = messages[messages.count - 1]
                    let file = FileInfo(name: name, path: path, size: size, mimeType: mimeType, inlineData: inlineData)
                    messages[messages.count - 1] = Message(
                        id: cur.id, serverId: cur.serverId, role: .assistant,
                        content: cur.content, attachment: cur.attachment, timestamp: cur.timestamp,
                        status: cur.status, thinkingText: cur.thinkingText, isStreaming: cur.isStreaming,
                        files: cur.files + [file], eventId: cur.eventId
                    )
                }
            case .finish:
                contentFlushTask?.cancel()
                contentFlushTask = nil
                flushContentThrottle()
                isStreaming = false
                if let last = messages.last, last.role == .assistant {
                    let cur = messages[messages.count - 1]
                    messages[messages.count - 1] = Message(
                        id: cur.id, serverId: cur.serverId, role: .assistant,
                        content: cur.content, attachment: cur.attachment, timestamp: cur.timestamp,
                        status: .sent, thinkingText: cur.thinkingText, isStreaming: false,
                        files: cur.files, eventId: cur.eventId
                    )
                }
                SessionStore.save(messages, sessionKey: sessionKey)
            case .errorFinish(let partial):
                contentFlushTask?.cancel()
                contentFlushTask = nil
                flushContentThrottle()
                isStreaming = false
                streamError = partial ? "回复可能不完整" : nil
                if let last = messages.last, last.role == .assistant {
                    let cur = messages[messages.count - 1]
                    messages[messages.count - 1] = Message(
                        id: cur.id, serverId: cur.serverId, role: .assistant,
                        content: cur.content, attachment: cur.attachment, timestamp: cur.timestamp,
                        status: partial ? .error : .sent, thinkingText: cur.thinkingText, isStreaming: false,
                        files: cur.files, eventId: cur.eventId
                    )
                }
                SessionStore.save(messages, sessionKey: sessionKey)
            }
        }
    }

    private func scheduleContentFlush() {
        guard contentFlushTask == nil else { return }
        contentFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.throttleIntervalMs ?? 150) * 1_000_000))
            await MainActor.run { [weak self] in
                self?.flushContentThrottle()
                self?.contentFlushTask = nil
            }
        }
    }

    private func flushContentThrottle() {
        guard !contentThrottleBuffer.isEmpty else { return }
        if let last = messages.last, last.role == .assistant {
            let cur = messages[messages.count - 1]
            messages[messages.count - 1] = Message(
                id: cur.id, serverId: cur.serverId, role: .assistant,
                content: cur.content + contentThrottleBuffer, attachment: cur.attachment, timestamp: cur.timestamp,
                status: cur.status, thinkingText: cur.thinkingText, isStreaming: cur.isStreaming,
                files: cur.files, eventId: cur.eventId
            )
        }
        contentThrottleBuffer = ""
        if isFollowing {
            followTick &+= 1
        }
    }
}
