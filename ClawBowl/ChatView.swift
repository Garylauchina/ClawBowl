import SwiftUI
import UIKit

// MARK: - Date Separator (Telegram-style)

private struct DateSeparator: View {
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

private func shouldShowDateSeparator(current: Message, previous: Message?) -> Bool {
    guard let prev = previous else { return true }
    return !Calendar.current.isDate(current.timestamp, inSameDayAs: prev.timestamp)
}

// MARK: - UIKit Bridge: Scroll Position Detection

/// 用引用类型保存是否在底部，避免在 KVO/异步回调里写 struct 的 Binding 导致悬空。
final class ScrollPositionState: ObservableObject {
    @Published var isAtBottom: Bool = true
}

/// 拦截系统「点击状态栏」：改为上翻一页并返回 false，其余 delegate 转发给原 delegate。
final class ScrollViewDelegateProxy: NSObject, UIScrollViewDelegate {
    weak var originalDelegate: UIScrollViewDelegate?
    var onScrollToTop: (() -> Void)?

    func scrollViewShouldScrollToTop(_ scrollView: UIScrollView) -> Bool {
        onScrollToTop?()
        return false
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if aSelector == #selector(UIScrollViewDelegate.scrollViewShouldScrollToTop(_:)) {
            return true
        }
        return originalDelegate?.responds(to: aSelector) ?? false
    }

    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if aSelector == #selector(UIScrollViewDelegate.scrollViewShouldScrollToTop(_:)) {
            return nil
        }
        return originalDelegate
    }
}

struct ScrollPositionHelper: UIViewRepresentable {
    @ObservedObject var state: ScrollPositionState
    let stopMomentumTrigger: UInt

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let v = UIView(frame: .zero)
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coord = context.coordinator
        coord.state = state
        if coord.scrollView == nil, coord.pendingAttach == nil {
            let work = DispatchWorkItem { [weak coord, weak uiView] in
                guard let coord, let uiView, coord.scrollView == nil,
                      uiView.window != nil else { return }
                coord.attach(from: uiView)
                coord.pendingAttach = nil
            }
            coord.pendingAttach = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }
        if coord.lastTrigger != stopMomentumTrigger {
            coord.lastTrigger = stopMomentumTrigger
            coord.stopMomentum()
        }
    }

    class Coordinator {
        weak var state: ScrollPositionState?
        weak var scrollView: UIScrollView?
        var delegateProxy: ScrollViewDelegateProxy?
        var observation: NSKeyValueObservation?
        var lastAtBottom = true
        var lastTrigger: UInt = 0
        var pendingAttach: DispatchWorkItem?
        private var pendingNotify: DispatchWorkItem?
        /// 节流：避免每次 contentOffset 都计算，连续滑动时减少主线程压力
        private var lastCheckTime: CFTimeInterval = 0
        private let throttleInterval: CFTimeInterval = 0.06

        private func checkPosition(_ sv: UIScrollView) {
            guard sv.window != nil else { return }
            let now = CACurrentMediaTime()
            guard now - lastCheckTime >= throttleInterval else { return }
            lastCheckTime = now

            guard sv.contentSize.height > 0, sv.frame.height > 0 else { return }
            let maxOffsetY = sv.contentSize.height
                + sv.adjustedContentInset.bottom
                - sv.frame.height
            let atBottom: Bool
            if maxOffsetY <= 0 {
                atBottom = true
            } else {
                let distanceFromBottom = maxOffsetY - sv.contentOffset.y
                atBottom = distanceFromBottom <= 32
            }
            guard atBottom != lastAtBottom else { return }
            lastAtBottom = atBottom
            notifyChange(atBottom)
        }

        /// 防抖：合并连续滑动时的多次更新；仅在实际变化时写 state，减少重入布局
        private func notifyChange(_ atBottom: Bool) {
            pendingNotify?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                if self.state?.isAtBottom != atBottom {
                    self.state?.isAtBottom = atBottom
                }
            }
            pendingNotify = work
            let deadline: DispatchTime = atBottom ? .now() : .now() + 0.12
            DispatchQueue.main.asyncAfter(deadline: deadline, execute: work)
        }

        func attach(from view: UIView) {
            var cur: UIView? = view
            while let p = cur?.superview {
                if let sv = p as? UIScrollView {
                    scrollView = sv
                    sv.scrollsToTop = true
                    let proxy = ScrollViewDelegateProxy()
                    proxy.originalDelegate = sv.delegate
                    proxy.onScrollToTop = { [weak self] in self?.scrollUpOnePage() }
                    sv.delegate = proxy
                    delegateProxy = proxy
                    observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                        self?.checkPosition(sv)
                    }
                    break
                }
                cur = p
            }
        }

        func stopMomentum() {
            guard let sv = scrollView else { return }
            sv.setContentOffset(sv.contentOffset, animated: false)
        }

        /// 上翻一页（由系统点击状态栏触发）
        func scrollUpOnePage() {
            guard let sv = scrollView, sv.window != nil else { return }
            let pageH = max(1, sv.bounds.height)
            let newY = max(-sv.adjustedContentInset.top, sv.contentOffset.y - pageH)
            sv.setContentOffset(CGPoint(x: 0, y: newY), animated: true)
        }
    }
}

// MARK: - Chat View

struct ChatView: View {
    @EnvironmentObject private var authService: AuthService
    @StateObject private var viewModel = ChatViewModel()
    @State private var inputText = ""
    @State private var selectedAttachment: Attachment?
    @State private var showLogoutAlert = false
    @State private var showCronView = false

    @StateObject private var scrollPositionState = ScrollPositionState()
    @State private var stopMomentumTrigger: UInt = 0
    @State private var replyingTo: Message?
    /// 延迟构建消息列表，避免 Splash→Chat 切换时同帧构建大视图树触发栈溢出（___chkstk_darwin）
    @State private var showMessageList = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if showMessageList {
                    messageList
                } else {
                    messageListPlaceholder
                }
                Divider()
                ChatInputBar(
                    text: $inputText,
                    selectedAttachment: $selectedAttachment,
                    replyingTo: $replyingTo,
                    isLoading: viewModel.isLoading,
                    onSend: {
                        let content = inputText
                        let att = selectedAttachment
                        let reply = replyingTo
                        inputText = ""
                        selectedAttachment = nil
                        replyingTo = nil
                        viewModel.sendMessage(content: content, attachment: att, replyTo: reply)
                    },
                    onStop: { viewModel.cancelStream() }
                )
            }
            .navigationTitle("ClawBowl")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    avatarMenu
                }
            }
            .sheet(isPresented: $showCronView) {
                CronView()
            }
            .onReceive(NotificationCenter.default.publisher(for: .didTapPushNotification)) { _ in
                showCronView = true
            }
            .alert("退出登录", isPresented: $showLogoutAlert) {
                Button("取消", role: .cancel) {}
                Button("退出", role: .destructive) {
                    authService.logout()
                }
            } message: {
                Text("确定要退出登录吗？")
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showMessageList = true
                }
            }
        }
    }

    /// 占位，避免切换时同帧构建 ScrollView+LazyVStack+ScrollPositionHelper 导致栈溢出
    private var messageListPlaceholder: some View {
        Color.clear
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    loadOlderTrigger
                    if viewModel.messages.isEmpty {
                        emptyStatePlaceholder
                    }
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.listId) { i, message in
                        let prev = i > 0 ? viewModel.messages[i - 1] : nil
                        MessageRowView(
                            message: message,
                            previousMessage: prev,
                            onMessageAppear: { viewModel.onMessageAppear(message.id) },
                            onReply: { replyingTo = $0 }
                        )
                    }
                }
                .padding(.vertical, 8)
                .background(ScrollPositionHelper(
                    state: scrollPositionState,
                    stopMomentumTrigger: stopMomentumTrigger
                ))
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable {
                await viewModel.refreshHistoryFromServer()
            }
            .onAppear {
                if let lastID = viewModel.messages.last?.listId {
                    proxy.scrollTo(lastID, anchor: .bottom)
                }
            }
            .onChange(of: viewModel.scrollTrigger) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.scrollAnchorAfterPrepend) { _ in
                guard let id = viewModel.scrollAnchorAfterPrepend else { return }
                viewModel.scrollAnchorAfterPrepend = nil
                withAnimation(.none) { proxy.scrollTo(id, anchor: .top) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !scrollPositionState.isAtBottom {
                Button {
                    stopMomentumTrigger &+= 1
                    viewModel.scrollTrigger &+= 1
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
            }
        }
        .animation(.easeInOut(duration: 0.25), value: scrollPositionState.isAtBottom)
        .overlay(alignment: .bottom) {
            if let notice = viewModel.filteredNotice {
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
    }

    // MARK: - Avatar Menu (replaces clear + cron + logout buttons)

    private var avatarMenu: some View {
        Menu {
            Button {
                showCronView = true
            } label: {
                Label("定时任务", systemImage: "clock")
            }
            Divider()
            Button(role: .destructive) {
                showLogoutAlert = true
            } label: {
                Label("退出登录", systemImage: "rectangle.portrait.and.arrow.right")
            }
        } label: {
            Text("G")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(
                    LinearGradient(
                        colors: [.blue, .cyan],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .clipShape(Circle())
        }
    }

    // MARK: - Scroll

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool = false) {
        guard scrollPositionState.isAtBottom else { return }
        guard let lastID = viewModel.messages.last?.listId else { return }
        if animated {
            withAnimation(.linear(duration: 0.12)) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        } else {
            withAnimation(.none) {
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
    }

    /// 首屏历史为空时展示（Telegram 式：服务端为首屏真相，空则提示发一句）
    private var emptyStatePlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 44))
                .foregroundColor(.secondary.opacity(0.6))
            Text("暂无消息")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("发一句开始对话")
                .font(.subheadline)
                .foregroundColor(.secondary.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.bottom, 20)
    }

    // MARK: - Message Row View (Performance Optimized)

    /// 顶部“加载更多”触发器（上滑出现即加载；下拉刷新也可加载更早）
    private var loadOlderTrigger: some View {
        Group {
            if viewModel.hasMoreHistory {
                ZStack(alignment: .center) {
                    Color.clear
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .id("load-older-trigger")
                        .onAppear {
                            Task { await viewModel.loadOlderMessagesIfNeeded() }
                        }
                    if viewModel.loadingOlder {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("加载更早消息…")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                    } else {
                        Text("上滑或下拉加载更早消息")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
        }
    }
}

// MARK: - Swipe to Reply Wrapper (Telegram-style)

struct SwipeToReplyWrapper<Content: View>: View {
    let message: Message
    let onReply: (Message) -> Void
    @ViewBuilder let content: () -> Content

    @State private var offset: CGFloat = 0
    private let threshold: CGFloat = 60

    var body: some View {
        ZStack(alignment: .leading) {
            if offset > 20 {
                Image(systemName: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 16))
                    .foregroundColor(.secondary.opacity(min(1, offset / threshold)))
                    .padding(.leading, 16)
            }
            content()
                .offset(x: offset)
        }
        .gesture(
            DragGesture(minimumDistance: 20)
                .onChanged { value in
                    let t = value.translation.width
                    if t > 0 { offset = min(t * 0.6, threshold * 1.2) }
                }
                .onEnded { value in
                    if offset >= threshold {
                        let impact = UIImpactFeedbackGenerator(style: .light)
                        impact.impactOccurred()
                        onReply(message)
                    }
                    withAnimation(.easeOut(duration: 0.2)) { offset = 0 }
                }
        )
    }
}

// MARK: - Message Row View (Performance Optimized)

private struct MessageRowView: View {
    let message: Message
    let previousMessage: Message?
    let onMessageAppear: () -> Void
    let onReply: (Message) -> Void

    var body: some View {
        Group {
            if shouldShowDateSeparator(current: message, previous: previousMessage) {
                DateSeparator(date: message.timestamp)
            }
            SwipeToReplyWrapper(message: message, onReply: onReply) {
                MessageBubble(message: message, onQuoteReply: onReply)
            }
            .id(message.listId)
            .onAppear(perform: onMessageAppear)
        }
    }
}

#Preview {
    ChatView()
}
