import SwiftUI

@main
struct ClawBowlApp: App {
    @StateObject private var authService = AuthService.shared
    @State private var splashDone = false

    var body: some Scene {
        WindowGroup {
            ZStack {
                // 始终铺底深色，消除白→深色的闪烁
                Color(red: 0.05, green: 0.05, blue: 0.15)
                    .ignoresSafeArea()

                if !splashDone {
                    // Splash 始终作为第一屏（不依赖 auth 状态）
                    SplashView {
                        withAnimation(.easeInOut(duration: 0.5)) {
                            splashDone = true
                        }
                    }
                    .transition(.opacity)
                } else if authService.isAuthenticated {
                    ChatView()
                        .environment(\.authService, authService)
                        .transition(.opacity)
                } else {
                    AuthView(authService: authService)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: splashDone)
            .animation(.easeInOut, value: authService.isAuthenticated)
        }
    }
}

// MARK: - Splash View

/// 启动欢迎屏：Logo + 随机趣味提示语，同时后台预热容器
struct SplashView: View {
    let onFinish: () -> Void

    // Logo 弹跳动画（从略小→标准尺寸，但始终可见）
    @State private var logoScale: CGFloat = 0.85
    @State private var pulseScale: CGFloat = 1.0
    @State private var dotCount = 0
    @State private var timerRef: Timer?

    /// 随机趣味提示语
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
        VStack(spacing: 24) {
            Spacer()

            // Logo — 始终可见，仅做弹跳+脉冲动画
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

            // 标题 — 始终可见
            Text("ClawBowl")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Spacer()

            // 趣味提示 — 始终可见
            Text(tip + String(repeating: ".", count: dotCount))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .frame(height: 20)

            Spacer()
                .frame(height: 60)
        }
        .onAppear {
            startAnimations()
            startWarmup()
        }
        .onDisappear {
            timerRef?.invalidate()
            timerRef = nil
        }
    }

    private func startAnimations() {
        // Logo 弹入（从 0.85 → 1.0，很快）
        withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
            logoScale = 1.0
        }

        // 持续脉冲呼吸动画
        withAnimation(
            .easeInOut(duration: 1.2)
            .repeatForever(autoreverses: true)
        ) {
            pulseScale = 1.06
        }

        // 加载点循环动画
        timerRef = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            dotCount = (dotCount + 1) % 4
        }
    }

    private func startWarmup() {
        // 最低显示 2.5 秒（用户能充分看到内容）
        let minimumDisplayNanos: UInt64 = 2_500_000_000

        Task {
            async let warmup: () = warmupContainer()
            async let delay: () = Task.sleep(nanoseconds: minimumDisplayNanos)

            _ = try? await warmup
            _ = try? await delay

            await MainActor.run {
                onFinish()
            }
        }
    }

    /// 预热后端容器
    private func warmupContainer() async {
        guard let token = AuthService.shared.accessToken,
              let url = URL(string: "https://prometheusclothing.net/api/v2/chat/warmup") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

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
