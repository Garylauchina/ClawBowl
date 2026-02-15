import SwiftUI

/// 聊天主视图
struct ChatView: View {
    @Environment(\.authService) private var authService
    @State private var messages: [Message] = [
        Message(role: .assistant, content: "你好！我是 AI 助手，有什么可以帮你的吗？")
    ]
    @State private var inputText = ""
    @State private var selectedImage: UIImage?
    @State private var isLoading = false
    @State private var showClearAlert = false
    @State private var showLogoutAlert = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 消息列表
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(messages) { message in
                                MessageBubble(message: message)
                                    .id(message.id)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: messages) { _ in
                        // Scroll on every streaming update
                        scrollToBottom(proxy: proxy)
                    }
                }

                Divider()

                // 输入栏
                ChatInputBar(
                    text: $inputText,
                    selectedImage: $selectedImage,
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
        let image = selectedImage
        guard !content.isEmpty || image != nil else { return }
        guard !isLoading else { return }

        // 清空输入
        inputText = ""
        selectedImage = nil
        isLoading = true

        Task {
            do {
                // 压缩图片
                var compressedData: Data?
                if let img = image {
                    compressedData = await ChatService.shared.compressImage(img)
                }

                // 添加用户消息
                let displayText = content.isEmpty && image != nil ? "[图片]" : content
                let userMessage = Message(
                    role: .user,
                    content: displayText,
                    imageData: compressedData
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
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        messages.append(placeholderMessage)
                    }
                }

                // 获取历史（不含占位消息）
                let historyMessages = Array(messages.dropLast(2))

                // 发起 SSE 流式请求
                let stream = try await ChatService.shared.sendMessageStream(
                    content,
                    imageData: compressedData,
                    history: historyMessages
                )

                // 逐事件更新占位消息
                for try await event in stream {
                    await MainActor.run {
                        guard let idx = messages.firstIndex(where: { $0.id == placeholderID }) else { return }
                        switch event {
                        case .thinking(let status):
                            messages[idx].thinkingText = status
                        case .content(let text):
                            messages[idx].content += text
                        case .done:
                            messages[idx].isStreaming = false
                        }
                    }
                }

                // 流结束
                await MainActor.run {
                    if let idx = messages.firstIndex(where: { $0.id == placeholderID }) {
                        messages[idx].isStreaming = false
                        // 如果内容为空说明 OpenClaw 没返回有效内容
                        if messages[idx].content.isEmpty && messages[idx].thinkingText.isEmpty {
                            messages[idx].content = "AI 未返回内容，请重试。"
                            messages[idx].status = .error
                        }
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    // 如果已有占位消息，更新为错误；否则新增
                    if let lastIdx = messages.indices.last,
                       messages[lastIdx].role == .assistant && messages[lastIdx].isStreaming {
                        messages[lastIdx].content = "抱歉，出了点问题：\(error.localizedDescription)。请稍后重试。"
                        messages[lastIdx].status = .error
                        messages[lastIdx].isStreaming = false
                    } else {
                        let errorMessage = Message(
                            role: .assistant,
                            content: "抱歉，出了点问题：\(error.localizedDescription)。请稍后重试。",
                            status: .error
                        )
                        withAnimation(.easeInOut(duration: 0.2)) {
                            messages.append(errorMessage)
                        }
                    }
                    isLoading = false
                }
            }
        }
    }

    private func clearChat() {
        withAnimation {
            messages = [
                Message(role: .assistant, content: "聊天记录已清空。有什么可以帮你的吗？")
            ]
            selectedImage = nil
        }
        Task {
            await ChatService.shared.resetSession()
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            withAnimation(.easeOut(duration: 0.2)) {
                if let lastId = messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
}

#Preview {
    ChatView()
}
