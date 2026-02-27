import SwiftUI
import UIKit

/// 底部锚点 ID，所有“滚到底”统一用此，避免 scrollTo(lastMessageId) 偏差
private let bottomSentinelID = "bottom-sentinel"

// MARK: - 日期分隔（与 ChatView 一致）

private struct ChatScreenDateSeparator: View {
    let date: Date

    var body: some View {
        Text(Self.formatDate(date))
            .font(.caption2.weight(.medium))
            .foregroundColor(.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(Color(.systemGray5).opacity(0.8))
            .clipShape(Capsule())
            .padding(.vertical, 6)
    }

    private static func formatDate(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "今天" }
        if cal.isDateInYesterday(date) { return "昨天" }
        let now = Date()
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            let f = DateFormatter()
            f.locale = Locale(identifier: "zh_CN")
            f.dateFormat = "M月d日"
            return f.string(from: date)
        }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "yyyy年M月d日"
        return f.string(from: date)
    }
}

private func chatScreenShowDateSeparator(current: Message, previous: Message?) -> Bool {
    guard let prev = previous else { return true }
    return !Calendar.current.isDate(current.timestamp, inSameDayAs: prev.timestamp)
}

// MARK: - 轻量距底/拖拽判定（仅用于 isFollowing，不引入 stopMomentum 等）

private final class ChatScrollFollowDelegate: NSObject, UIScrollViewDelegate {
    weak var originalDelegate: UIScrollViewDelegate?
    var onUserScrolledUp: (() -> Void)?
    private let distanceThreshold: CGFloat = 80

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(UIScrollViewDelegate.scrollViewDidScroll(_:)) { return true }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == #selector(UIScrollViewDelegate.scrollViewDidScroll(_:)) { return nil }
        return originalDelegate
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let bottomY = scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - scrollView.bounds.height
        let distance = bottomY - scrollView.contentOffset.y
        if (scrollView.isDragging || scrollView.isDecelerating), distance > distanceThreshold {
            onUserScrolledUp?()
        }
        (originalDelegate as? UIScrollViewDelegate)?.scrollViewDidScroll?(scrollView)
    }
}

private struct ChatScrollFollowBridge: UIViewRepresentable {
    var onUserScrolledUp: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onUserScrolledUp: onUserScrolledUp) }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        coord.onUserScrolledUp = onUserScrolledUp
        if coord.scrollView == nil, coord.pendingAttach == nil {
            let work = DispatchWorkItem { [weak coord, weak uiView] in
                guard let coord, let uiView, coord.scrollView == nil, uiView.window != nil else { return }
                coord.attach(from: uiView)
                coord.pendingAttach = nil
            }
            coord.pendingAttach = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
    }

    class Coordinator {
        var onUserScrolledUp: () -> Void
        weak var scrollView: UIScrollView?
        var delegateProxy: ChatScrollFollowDelegate?
        var observation: NSKeyValueObservation?
        var pendingAttach: DispatchWorkItem?

        init(onUserScrolledUp: @escaping () -> Void) {
            self.onUserScrolledUp = onUserScrolledUp
        }

        func attach(from view: UIView) {
            var cur: UIView? = view
            while let p = cur?.superview {
                if let sv = p as? UIScrollView {
                    scrollView = sv
                    let proxy = ChatScrollFollowDelegate()
                    proxy.originalDelegate = sv.delegate
                    proxy.onUserScrolledUp = { [weak self] in
                        DispatchQueue.main.async { self?.onUserScrolledUp() }
                    }
                    sv.delegate = proxy
                    delegateProxy = proxy
                    break
                }
                cur = p
            }
        }
    }
}

// MARK: - 单会话聊天页（承载消息列表 + 输入栏，事件经 Reducer 收敛）

struct ChatScreen: View {
    let sessionKey: String

    @StateObject private var viewModel: ChatScreenViewModel
    @State private var inputText = ""
    @State private var selectedAttachment: Attachment?
    @State private var snapToBottomTick: UInt = 0
    @State private var snapScrollTask: Task<Void, Never>?

    init(sessionKey: String) {
        self.sessionKey = sessionKey
        _viewModel = StateObject(wrappedValue: ChatScreenViewModel(sessionKey: sessionKey))
    }

    var body: some View {
        VStack(spacing: 0) {
            messageList
            Divider()
            ChatInputBar(
                text: $inputText,
                selectedAttachment: $selectedAttachment,
                replyingTo: .constant(nil),
                isLoading: viewModel.isStreaming,
                onSend: sendTapped,
                onStop: { viewModel.stopStreaming() }
            )
        }
        .navigationTitle(topicTitle)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewModel.onAppear() }
        .onDisappear {
            snapScrollTask?.cancel()
            snapScrollTask = nil
            viewModel.onDisappear()
        }
        .overlay(alignment: .bottomTrailing) {
            if !viewModel.isFollowing && viewModel.messages.count > 0 {
                Button {
                    viewModel.scrollToBottom()
                    snapToBottomTick &+= 1
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
            }
        }
        .animation(.easeInOut(duration: 0.25), value: viewModel.isFollowing)
        .overlay(alignment: .bottom) {
            if let err = viewModel.streamError {
                Text("⚠️ \(err)")
                    .font(.footnote)
                    .foregroundColor(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.orange)
                    .clipShape(Capsule())
                    .padding(.bottom, 8)
            }
        }
    }

    private var topicTitle: String {
        if sessionKey.hasPrefix("ios:") || sessionKey.contains("_") {
            return "话题"
        }
        return sessionKey
    }

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if viewModel.messages.isEmpty {
                        emptyPlaceholder
                    }
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.listId) { index, message in
                        let prev = index > 0 ? viewModel.messages[index - 1] : nil
                        if chatScreenShowDateSeparator(current: message, previous: prev) {
                            ChatScreenDateSeparator(date: message.timestamp)
                        }
                        MessageBubble(message: message, onQuoteReply: nil)
                            .id(message.listId)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id(bottomSentinelID)
                }
                .padding(.vertical, 8)
            }
            .scrollDismissesKeyboard(.immediately)
            .background(ChatScrollFollowBridge(onUserScrolledUp: { viewModel.isFollowing = false }))
            .onAppear {
                proxy.scrollTo(bottomSentinelID, anchor: .bottom)
            }
            .onChange(of: viewModel.followTick) { _ in
                if viewModel.isFollowing {
                    proxy.scrollTo(bottomSentinelID, anchor: .bottom)
                }
            }
            .onChange(of: snapToBottomTick) { tick in
                guard tick > 0 else { return }
                snapScrollTask?.cancel()
                snapScrollTask = Task {
                    proxy.scrollTo(bottomSentinelID, anchor: .bottom)
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(bottomSentinelID, anchor: .bottom)
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    guard !Task.isCancelled else { return }
                    proxy.scrollTo(bottomSentinelID, anchor: .bottom)
                }
            }
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("暂无消息")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
    }

    private func sendTapped() {
        let content = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let att = selectedAttachment
        inputText = ""
        selectedAttachment = nil
        guard !content.isEmpty || att != nil else { return }
        Task {
            await viewModel.sendMessage(content: content, attachment: att)
        }
    }
}

#Preview {
    NavigationStack {
        ChatScreen(sessionKey: "preview-session")
    }
}
