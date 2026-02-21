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
        coord.parent = self
        if coord.scrollView == nil {
            DispatchQueue.main.async { coord.attach(from: uiView) }
        }
        if coord.lastTrigger != stopMomentumTrigger {
            coord.lastTrigger = stopMomentumTrigger
            coord.stopMomentum()
        }
    }

    class Coordinator {
        var parent: ScrollPositionHelper
        weak var scrollView: UIScrollView?
        var observation: NSKeyValueObservation?
        var lastAtBottom = true
        var lastTrigger: UInt = 0
        private var pendingNotify: DispatchWorkItem?

        init(parent: ScrollPositionHelper) { self.parent = parent }

        func attach(from view: UIView) {
            var cur: UIView? = view
            while let p = cur?.superview {
                if let sv = p as? UIScrollView {
                    scrollView = sv
                    observation = sv.observe(\.contentOffset, options: [.new]) { [weak self] sv, _ in
                        self?.checkPosition(sv)
                    }
                    break
                }
                cur = p
            }
        }

        private func checkPosition(_ sv: UIScrollView) {
            guard sv.contentSize.height > 0, sv.frame.height > 0 else { return }
            let maxOffsetY = sv.contentSize.height
                + sv.adjustedContentInset.bottom
                - sv.frame.height
            let atBottom: Bool
            if maxOffsetY <= 0 {
                atBottom = true
            } else {
                let distanceFromBottom = maxOffsetY - sv.contentOffset.y
                atBottom = distanceFromBottom <= 80
            }
            guard atBottom != lastAtBottom else { return }
            lastAtBottom = atBottom
            notifyChange(atBottom)
        }

        private func notifyChange(_ atBottom: Bool) {
            pendingNotify?.cancel()
            pendingNotify = nil
            if atBottom {
                DispatchQueue.main.async {
                    self.parent.isAtBottom = true
                }
            } else {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.parent.isAtBottom = false
                }
                pendingNotify = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
            }
        }

        func stopMomentum() {
            guard let sv = scrollView else { return }
            sv.setContentOffset(sv.contentOffset, animated: false)
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

    @State private var isAtBottom = true
    @State private var stopMomentumTrigger: UInt = 0
    @State private var scrollProxy: ScrollViewProxy?
    @State private var replyingTo: Message?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                messageList
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
        }
    }

    // MARK: - Message List

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(viewModel.messages.enumerated()), id: \.element.id) { index, message in
                        let prev = index > 0 ? viewModel.messages[index - 1] : nil
                        if shouldShowDateSeparator(current: message, previous: prev) {
                            DateSeparator(date: message.timestamp)
                        }
                        SwipeToReplyWrapper(message: message, onReply: { replyingTo = $0 }) {
                            MessageBubble(message: message, onQuoteReply: { replyingTo = $0 })
                        }
                        .id(message.id)
                        .onAppear {
                            viewModel.onMessageAppear(message.id)
                        }
                    }
                }
                .padding(.vertical, 8)
                .background(ScrollPositionHelper(
                    isAtBottom: $isAtBottom,
                    stopMomentumTrigger: stopMomentumTrigger
                ))
            }
            .scrollDismissesKeyboard(.immediately)
            .onAppear {
                scrollProxy = proxy
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    if let lastID = viewModel.messages.last?.id {
                        proxy.scrollTo(lastID, anchor: .bottom)
                    }
                }
            }
            .onChange(of: viewModel.messages.count) { _ in
                scrollToBottom(proxy: proxy)
            }
            .onChange(of: viewModel.scrollTrigger) { _ in
                scrollToBottom(proxy: proxy)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !isAtBottom {
                Button {
                    stopMomentumTrigger &+= 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                        if let proxy = scrollProxy, let lastID = viewModel.messages.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
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
            }
        }
        .animation(.easeInOut(duration: 0.25), value: isAtBottom)
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

    private func scrollToBottom(proxy: ScrollViewProxy) {
        guard let lastID = viewModel.messages.last?.id else { return }
        DispatchQueue.main.async {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

// MARK: - Swipe to Reply Wrapper (Telegram-style)

private struct SwipeToReplyWrapper<Content: View>: View {
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

#Preview {
    ChatView()
}
