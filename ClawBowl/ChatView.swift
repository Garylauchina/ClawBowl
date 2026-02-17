import SwiftUI
import UIKit

// MARK: - UIKit 桥接：可靠检测滚动位置 + 惯性滚动时也能滚到底部

/// UIKit 桥接：KVO 检测滚动位置 + 停止惯性滚动
/// - 检测：KVO 监听 contentOffset，计算是否在底部（考虑 adjustedContentInset）
/// - 停止惯性：setContentOffset(当前位置, animated:false)
/// - 实际滚动：由外部 SwiftUI proxy.scrollTo 完成（走身份系统，不依赖 contentSize 估算）
struct ScrollPositionHelper: UIViewRepresentable {
    @Binding var isAtBottom: Bool
    let stopMomentumTrigger: UInt

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        if coord.scrollView == nil {
            DispatchQueue.main.async { coord.attach(from: uiView) }
        }
        // 响应"停止惯性"触发
        if coord.lastTrigger != stopMomentumTrigger {
            coord.lastTrigger = stopMomentumTrigger
            coord.stopMomentum()
        }
    }

    class Coordinator {
        let parent: ScrollPositionHelper
        weak var scrollView: UIScrollView?
        var observation: NSKeyValueObservation?
        var lastAtBottom = true
        var lastTrigger: UInt = 0

        init(parent: ScrollPositionHelper) { self.parent = parent }

        func attach(from view: UIView) {
            var cur: UIView? = view
            while let p = cur?.superview {
                if let sv = p as? UIScrollView {
                    scrollView = sv
                    observation = sv.observe(\.contentOffset, options: [.new, .initial]) { [weak self] sv, _ in
                        self?.checkPosition(sv)
                    }
                    break
                }
                cur = p
            }
        }

        private func checkPosition(_ sv: UIScrollView) {
            guard sv.contentSize.height > 0, sv.frame.height > 0 else { return }
            let inset = sv.adjustedContentInset
            let maxOffset = sv.contentSize.height + inset.top + inset.bottom - sv.frame.height
            if maxOffset <= 0 {
                // 内容不足一屏，始终视为在底部
                if !lastAtBottom { lastAtBottom = true; notifyChange(true) }
                return
            }
            let distanceFromBottom = maxOffset - sv.contentOffset.y
            let atBottom = distanceFromBottom <= 80
            guard atBottom != lastAtBottom else { return }
            lastAtBottom = atBottom
            notifyChange(atBottom)
        }

        private func notifyChange(_ atBottom: Bool) {
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.2)) {
                    self.parent.isAtBottom = atBottom
                }
            }
        }

        /// 只停止惯性，不做任何滚动（同步执行）
        func stopMomentum() {
            guard let sv = scrollView else { return }
            sv.setContentOffset(sv.contentOffset, animated: false)
        }
    }
}

/// 聊天主视图
struct ChatView: View {
    @Environment(\.authService) private var authService
    @State private var messages: [Message] = {
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
    /// UIKit KVO 检测：当前是否在底部
    @State private var isAtBottom = true
    /// 触发 UIKit 停止惯性滚动（递增即触发）
    @State private var stopMomentumTrigger: UInt = 0
    /// 存储 ScrollViewProxy，供按钮在停止惯性后调用 scrollTo
    @State private var scrollProxy: ScrollViewProxy?
    /// Ready Gate：等待占位气泡渲染完成后再发请求
    @State private var readyContinuation: CheckedContinuation<Void, Never>?
    @State private var pendingReadyID: UUID?
    /// 内容过滤提示（短暂显示后自动消失）
    @State private var filteredNotice: String?

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
                                    .onAppear {
                                        // Ready Gate
                                        if message.id == pendingReadyID {
                                            pendingReadyID = nil
                                            readyContinuation?.resume()
                                            readyContinuation = nil
                                        }
                                    }
                            }
                        }
                        .padding(.vertical, 8)
                        // UIKit 桥接：检测位置 + 停止惯性
                        .background(ScrollPositionHelper(
                            isAtBottom: $isAtBottom,
                            stopMomentumTrigger: stopMomentumTrigger
                        ))
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onAppear {
                        scrollProxy = proxy
                        // 启动时自动滚动到最新消息
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                            if let lastID = messages.last?.id {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: messages.count) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                    .onChange(of: scrollTrigger) { _ in
                        scrollToBottom(proxy: proxy)
                    }
                }
                // 浮动"回到底部"按钮（完全在 ScrollView 外层）
                .overlay(alignment: .bottomTrailing) {
                    if !isAtBottom {
                        Button {
                            // 第一步：UIKit 停止惯性（同步）
                            stopMomentumTrigger &+= 1
                            // 第二步：SwiftUI 滚到最后一条消息（走身份系统，位置精确）
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                if let proxy = scrollProxy, let lastID = messages.last?.id {
                                    withAnimation(.easeOut(duration: 0.3)) {
                                        proxy.scrollTo(lastID, anchor: .bottom)
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(.white)
                                .frame(width: 44, height: 44)
                                .background(Color.accentColor.opacity(0.85))
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                        }
                        .padding(.trailing, 16)
                        .padding(.bottom, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .animation(.easeInOut(duration: 0.2), value: isAtBottom)
                    }
                }

                // 内容过滤提示横幅
                .overlay(alignment: .bottom) {
                    if let notice = filteredNotice {
                        Text(notice)
                            .font(.footnote)
                            .foregroundColor(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .background(Color.orange.opacity(0.9))
                            .cornerRadius(20)
                            .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                            .padding(.bottom, 8)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
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
                var wasFiltered = false
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
                        case .filtered(let text):
                            messages[idx].content = text
                            messages[idx].thinkingText = ""
                            messages[idx].status = .filtered
                            messages[idx].isStreaming = false
                            wasFiltered = true
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
                    if wasFiltered {
                        // 自动清洗：移除最近 2 轮对话（当前 filtered 对 + 上一轮可能含敏感内容的对）
                        let removeCount = min(messages.count, 4)
                        messages.removeLast(removeCount)
                        MessageStore.save(messages)
                        withAnimation(.easeInOut(duration: 0.3)) {
                            filteredNotice = "检测到内容限制，已自动清理相关对话，请继续"
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            withAnimation(.easeInOut(duration: 0.5)) {
                                filteredNotice = nil
                            }
                        }
                    } else {
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
                        MessageStore.save(messages)
                    }
                    isLoading = false
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

    /// 流式期间自动跟随最新消息（无动画，避免队列堆积）
    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastID = messages.last?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

#Preview {
    ChatView()
}
