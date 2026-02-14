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

                            // 思考中动画
                            if isLoading {
                                ThinkingIndicator()
                                    .id("thinking")
                                    .transition(.opacity)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: messages.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: isLoading) { _ in
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

        // 异步：先压缩图片，再显示消息和调用 API
        Task {
            do {
                // 压缩图片（同一份数据用于显示和 API）
                var compressedData: Data?
                if let img = image {
                    compressedData = await ChatService.shared.compressImage(img)
                }

                // 添加用户消息（用压缩后的图片）
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

                let historyMessages = Array(messages.dropLast())
                let reply = try await ChatService.shared.sendMessage(
                    content,
                    imageData: compressedData,
                    history: historyMessages
                )
                let assistantMessage = Message(role: .assistant, content: reply)
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        messages.append(assistantMessage)
                        isLoading = false
                    }
                }
            } catch {
                let errorMessage = Message(
                    role: .assistant,
                    content: "抱歉，出了点问题：\(error.localizedDescription)。请稍后重试。",
                    status: .error
                )
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        messages.append(errorMessage)
                        isLoading = false
                    }
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
                if isLoading {
                    proxy.scrollTo("thinking", anchor: .bottom)
                } else if let lastId = messages.last?.id {
                    proxy.scrollTo(lastId, anchor: .bottom)
                }
            }
        }
    }
}

/// "正在思考" 动画指示器
struct ThinkingIndicator: View {
    @State private var animating = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // AI 头像
            Text("AI")
                .font(.caption.bold())
                .foregroundColor(.white)
                .frame(width: 36, height: 36)
                .background(
                    LinearGradient(colors: [.purple, .indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
                )
                .clipShape(Circle())

            // 思考气泡
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .scaleEffect(animating ? 1.2 : 0.7)
                        .opacity(animating ? 1 : 0.4)
                        .animation(
                            .easeInOut(duration: 0.6)
                                .repeatForever()
                                .delay(Double(index) * 0.2),
                            value: animating
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.systemGray6))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .onAppear { animating = true }
    }
}

#Preview {
    ChatView()
}
