import SwiftUI

/// 聊天主视图
struct ChatView: View {
    @Environment(\.authService) private var authService
    @State private var messages: [Message] = {
        // 启动时恢复上次的聊天记录；没有则显示默认问候
        if let saved = MessageStore.load() {
            return saved
        }
        return [Message(role: .assistant, content: "你好！我是 AI 助手，有什么可以帮你的吗？")]
    }()
    @State private var inputText = ""
    @State private var selectedAttachment: Attachment?
    @State private var isLoading = false
    @State private var showClearAlert = false
    @State private var showLogoutAlert = false
    /// 轻量滚动触发器：streaming 时递增此值代替对整个 messages 的全量比较
    @State private var scrollTrigger: UInt = 0
    /// 用户是否不在对话底部（控制浮动按钮显示）
    @State private var showScrollToBottom = false
    /// Ready Gate：等待占位气泡渲染完成后再发请求
    @State private var readyContinuation: CheckedContinuation<Void, Never>?
    @State private var pendingReadyID: UUID?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 消息列表
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(messages) { message in
                                    MessageBubble(message: message)
                                        .id(message.id)
                                        .onAppear {
                                            // Ready Gate
                                            if message.id == pendingReadyID {
                                                pendingReadyID = nil
                                                readyContinuation?.resume()
                                                readyContinuation = nil
                                            }
                                            // 最后一条消息可见 → 用户在底部，隐藏按钮
                                            if message.id == messages.last?.id {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    showScrollToBottom = false
                                                }
                                            }
                                        }
                                        .onDisappear {
                                            // 最后一条消息不可见 → 用户不在底部，显示按钮
                                            if message.id == messages.last?.id {
                                                withAnimation(.easeInOut(duration: 0.2)) {
                                                    showScrollToBottom = true
                                                }
                                            }
                                        }
                                }
                                // 底部锚点（仅用于 scrollTo 目标，不承担可见性检测）
                                Color.clear
                                    .frame(height: 1)
                                    .id("bottom-anchor")
                            }
                            .padding(.vertical, 8)
                        }
                        .scrollDismissesKeyboard(.interactively)
                        .onAppear {
                            // 启动时自动滚动到最新消息（聊天 app 标准行为）
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                                if let lastID = messages.last?.id {
                                    proxy.scrollTo(lastID, anchor: .bottom)
                                }
                            }
                        }
                        .onChange(of: messages.count) { _ in
                            scrollToBottom(proxy: proxy, animated: true)
                        }
                        .onChange(of: scrollTrigger) { _ in
                            // streaming 期间不加动画，避免动画队列堆积
                            scrollToBottom(proxy: proxy, animated: false)
                        }

                        // 浮动"回到底部"按钮
                        if showScrollToBottom {
                            Button {
                                scrollToBottom(proxy: proxy, animated: true)
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 36, height: 36)
                                    .background(Color.accentColor.opacity(0.85))
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                            }
                            .padding(.trailing, 16)
                            .padding(.bottom, 8)
                            .transition(.opacity.combined(with: .scale(scale: 0.8)))
                            .animation(.easeInOut(duration: 0.2), value: showScrollToBottom)
                        }
                    }
                }

                Divider()

                // 输入栏
                ChatInputBar(
                    text: $inputText,
                    selectedAttachment: $selectedAttachment,
                    isLoading: isLoading
                ) {
                    sendMessage()
                }
            }
            .navigationTitle("ClawBowl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(action: { showLogoutAlert = true }) {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("清空") {
                        showClearAlert = true
                    }
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                }
            }
            .alert("清空聊天", isPresented: $showClearAlert) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    clearChat()
                }
            } message: {
                Text("确定要清空所有聊天记录吗？")
            }
            .alert("退出登录", isPresented: $showLogoutAlert) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    authService.logout()
                }
            } message: {
                Text("确定要退出登录吗？")
            }
        }
    }

    // MARK: - Actions

    private func sendMessage() {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachment = selectedAttachment
        guard !content.isEmpty || attachment != nil else { return }
        guard !isLoading else { return }

        // 清空输入
        inputText = ""
        selectedAttachment = nil
        isLoading = true

        Task {
            do {
                // 添加用户消息
                let displayText: String
                if content.isEmpty {
                    if let att = attachment {
                        displayText = att.isImage ? "[图片]" : "[文件: \(att.filename)]"
                    } else {
                        displayText = ""
                    }
                } else {
                    displayText = content
                }

                let userMessage = Message(
                    role: .user,
                    content: displayText,
                    attachment: attachment
                )
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        messages.append(userMessage)
                    }
                }

                // 创建流式占位 assistant 消息
                let placeholderMessage = Message(
                    role: .assistant,
                    content: "",
                    isStreaming: true
                )
                let placeholderID = placeholderMessage.id

                // Ready Gate：先设置等待目标，再 append，确保 onAppear 能匹配
                await MainActor.run {
                    pendingReadyID = placeholderID
                    withAnimation(.easeInOut(duration: 0.2)) {
                        messages.append(placeholderMessage)
                    }
                }

                // 等待占位气泡渲染完成（onAppear 会 resume）
                await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                    if pendingReadyID == nil {
                        // onAppear 已经在 append 的同步周期内触发了
                        cont.resume()
                    } else {
                        readyContinuation = cont
                        // 安全超时：500ms 后强制放行，防止极端情况死锁
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            guard readyContinuation != nil else { return }
                            readyContinuation?.resume()
                            readyContinuation = nil
                            pendingReadyID = nil
                        }
                    }
                }

                // ── UI Ready，开始发请求 ──

                // 获取历史（不含占位消息）
                let historyMessages = Array(messages.dropLast(2))

                // 发起 SSE 流式请求
                let stream = try await ChatService.shared.sendMessageStream(
                    content,
                    attachment: attachment,
                    history: historyMessages
                )

                // 逐事件更新占位消息
                for try await event in stream {
                    await MainActor.run {
                        guard let idx = messages.firstIndex(where: { $0.id == placeholderID }) else { return }
                        switch event {
                        case .thinking(let status):
                            messages[idx].thinkingText += status
                            // 截断超长文本防止 UI 卡顿（保留最近 800 字符）
                            if messages[idx].thinkingText.count > 1000 {
                                let text = messages[idx].thinkingText
                                let start = text.index(text.endIndex, offsetBy: -800)
                                messages[idx].thinkingText = "…" + String(text[start...])
                            }
                        case .content(let text):
                            if !messages[idx].thinkingText.isEmpty {
                                messages[idx].thinkingText = ""
                                messages[idx].content = text  // 替换（首次）
                            } else {
                                messages[idx].content += text  // 追加（后续）
                            }
                            scrollTrigger &+= 1
                        case .done:
                            messages[idx].isStreaming = false
                            if !messages[idx].content.isEmpty {
                                messages[idx].thinkingText = ""
                            }
                        }
                    }
                }

                // 流结束
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.id == placeholderID }) {
                        messages[idx].isStreaming = false
                        if !messages[idx].content.isEmpty {
                            messages[idx].thinkingText = ""
                        }
                        if messages[idx].content.isEmpty && messages[idx].thinkingText.isEmpty {
                            messages[idx].content = "AI 未返回内容，请重试。"
                            messages[idx].status = .error
                        }
                    }
                    isLoading = false
                    MessageStore.save(messages)  // 持久化
                }
            } catch {
                await MainActor.run {
                    let friendlyMsg = Self.friendlyErrorMessage(for: error)
                    if let lastIdx = messages.indices.last,
                       messages[lastIdx].role == .assistant && messages[lastIdx].isStreaming {
                        messages[lastIdx].content = friendlyMsg
                        messages[lastIdx].status = .error
                        messages[lastIdx].isStreaming = false
                        messages[lastIdx].thinkingText = ""
                    } else {
                        let errorMessage = Message(
                            role: .assistant,
                            content: friendlyMsg,
                            status: .error
                        )
                        withAnimation(.easeInOut(duration: 0.2)) {
                            messages.append(errorMessage)
                        }
                    }
                    isLoading = false
                    MessageStore.save(messages)
                }
            }
        }
    }

    private func clearChat() {
        withAnimation {
            messages = [
                Message(role: .assistant, content: "聊天记录已清空。有什么可以帮你的吗？")
            ]
            selectedAttachment = nil
        }
        MessageStore.clear()  // 清除持久化数据
        Task {
            await ChatService.shared.resetSession()
        }
    }

    /// 将技术错误转换为用户友好的提示（后端已包装大部分错误，此处兜底前端/网络层错误）
    private static func friendlyErrorMessage(for error: Error) -> String {
        // ChatError 已经有友好描述
        if let chatError = error as? ChatError {
            return chatError.localizedDescription
        }

        let desc = error.localizedDescription.lowercased()

        // 网络连接类
        if desc.contains("network") || desc.contains("internet") || desc.contains("offline")
            || desc.contains("not connected") {
            return "网络连接异常，请检查网络后重试"
        }

        // 超时类
        if desc.contains("timed out") || desc.contains("timeout") {
            return "请求超时，AI 可能正在处理复杂任务，请稍后重试"
        }

        // SSL/安全类
        if desc.contains("ssl") || desc.contains("certificate") || desc.contains("trust") {
            return "安全连接异常，请稍后重试"
        }

        // 取消（用户主动或系统）
        if desc.contains("cancel") {
            return "请求已取消"
        }

        // 兜底：不暴露技术细节
        return "服务暂时不可用，请稍后重试"
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = true) {
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom-anchor", anchor: .bottom)
                }
            }
        } else {
            // 流式期间：无动画，直接跳转，避免动画队列堆积
            DispatchQueue.main.async {
                proxy.scrollTo("bottom-anchor", anchor: .bottom)
            }
        }
    }
}

#Preview {
    ChatView()
}
