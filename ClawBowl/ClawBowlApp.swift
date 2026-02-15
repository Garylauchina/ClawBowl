import SwiftUI

@main
struct ClawBowlApp: App {
    @StateObject private var authService = AuthService.shared
    @State private var splashDone = false

    var body: some Scene {
        WindowGroup {
            if !splashDone {
                // ── Splash 阶段：深色全屏 ──
                SplashView {
                    withAnimation(.easeInOut(duration: 0.35)) {
                        splashDone = true
                    }
                }
            } else if authService.isAuthenticated {
                // ── 正常聊天界面：不包裹任何额外容器，还原原始布局 ──
                ChatView()
                    .environment(\.authService, authService)
            } else {
                AuthView(authService: authService)
            }
        }
    }
}

// MARK: - Splash View

/// 启动欢迎屏：Logo + 随机趣味提示语，同时后台预热容器（fire-and-forget）
struct SplashView: View {
    let onFinish: () -> Void

    @State private var logoScale: CGFloat = 0.85
    @State private var pulseScale: CGFloat = 1.0
    @State private var dotCount = 0
    @State private var timerRef: Timer?

    private static let tips = [
        "正在唤醒你的 AI 助手",
        "连接数字灵魂中",
        "准备好了吗？",
        "AI 正在热身",
        "正在为你打开专属工作站",
        "数字世界的大门正在开启",
        "正在加载你的私人助理",
        "一切就绪，马上开始",
        "你的 AI 已经等不及了",
        "灵魂上线中",
        "正在同步记忆",
        "初始化创造力引擎",
    ]

    private let tip = tips.randomElement() ?? "加载中"

    var body: some View {
        ZStack {
            // Splash 专属深色背景
            Color(red: 0.05, green: 0.05, blue: 0.15)
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan, .teal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(logoScale * pulseScale)

                Text("ClawBowl")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                Spacer()

                Text(tip + String(repeating: ".", count: dotCount))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .frame(height: 20)

                Spacer()
                    .frame(height: 60)
            }
        }
        .onAppear {
            startAnimations()
            startBackgroundWarmup()
            scheduleSplashDismiss()
        }
        .onDisappear {
            timerRef?.invalidate()
            timerRef = nil
        }
    }

    // MARK: - Animations

    private func startAnimations() {
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            logoScale = 1.0
        }
        withAnimation(
            .easeInOut(duration: 1.2)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.06
        }
        timerRef = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }

    // MARK: - 后台预热（fire-and-forget，不阻塞 Splash 退出）

    /// 在后台启动初始化任务。这些任务不阻塞 Splash 消失。
    /// 即使 Splash 先退出，预热也会继续在后台完成。
    private func startBackgroundWarmup() {
        Task(priority: .userInitiated) {
            // ① Token 刷新（2 秒超时，不等到 15 秒）
            await refreshTokenQuick()

            // ② 预热容器（3 秒超时）
            await warmupContainerQuick()

            // ③ ChatService 单例
            _ = ChatService.shared
        }
    }

    /// Splash 固定显示 2.5 秒后退出，不等待任何网络请求
    private func scheduleSplashDismiss() {
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                onFinish()
            }
        }
    }

    /// 快速刷新 token（短超时，失败就跳过）
    private func refreshTokenQuick() async {
        guard AuthService.shared.accessToken != nil else { return }

        // 用 TaskGroup + sleep 实现 2 秒超时
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                try? await AuthService.shared.refreshToken()
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            // 第一个完成就返回（refresh 完成 或 2秒超时）
            await group.next()
            group.cancelAll()
        }
    }

    /// 快速预热容器（短超时，失败就跳过）
    private func warmupContainerQuick() async {
        guard let token = AuthService.shared.accessToken,
              let url = URL(string: "https://prometheusclothing.net/api/v2/chat/warmup") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 3  // 3 秒超时（不是 15 秒）

        _ = try? await URLSession.shared.data(for: request)
    }
}

// MARK: - Environment Key

private struct AuthServiceKey: EnvironmentKey {
    static let defaultValue: AuthService = AuthService.shared
}

extension EnvironmentValues {
    var authService: AuthService {
        get { self[AuthServiceKey.self] }
        set { self[AuthServiceKey.self] = newValue }
    }
}
