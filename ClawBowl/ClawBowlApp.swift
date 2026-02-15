import SwiftUI

@main
struct ClawBowlApp: App {
    @StateObject private var authService = AuthService.shared
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            Group {
                if showSplash && authService.isAuthenticated {
                    SplashView {
                        withAnimation(.easeInOut(duration: 0.4)) {
                            showSplash = false
                        }
                    }
                } else if authService.isAuthenticated {
                    ChatView()
                        .environment(\.authService, authService)
                } else {
                    AuthView(authService: authService)
                }
            }
            .animation(.easeInOut, value: authService.isAuthenticated)
        }
    }
}

// MARK: - Splash View

/// 启动欢迎屏：显示 Logo + 随机趣味提示语，同时后台预热容器
struct SplashView: View {
    let onFinish: () -> Void

    @State private var logoScale: CGFloat = 0.6
    @State private var logoOpacity: Double = 0
    @State private var textOpacity: Double = 0
    @State private var dotCount = 0

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
        ZStack {
            // 背景渐变
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.05, blue: 0.15),
                    Color(red: 0.1, green: 0.1, blue: 0.25),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Logo
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan, .teal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(logoScale)
                    .opacity(logoOpacity)

                // 标题
                Text("ClawBowl")
                    .font(.system(size: 36, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .opacity(logoOpacity)

                Spacer()

                // 趣味提示
                Text(tip + String(repeating: ".", count: dotCount))
                    .font(.subheadline)
                    .foregroundColor(.white.opacity(0.6))
                    .opacity(textOpacity)
                    .frame(height: 20)

                Spacer()
                    .frame(height: 60)
            }
        }
        .onAppear {
            startAnimations()
            startWarmup()
        }
    }

    private func startAnimations() {
        // Logo 入场
        withAnimation(.spring(response: 0.8, dampingFraction: 0.6)) {
            logoScale = 1.0
            logoOpacity = 1.0
        }

        // 提示语渐入
        withAnimation(.easeIn(duration: 0.6).delay(0.4)) {
            textOpacity = 1.0
        }

        // 加载点动画
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { timer in
            dotCount = (dotCount + 1) % 4
            if !showingSplash {
                timer.invalidate()
            }
        }
    }

    // 追踪是否还在显示（用于停止 timer）
    @State private var showingSplash = true

    private func startWarmup() {
        let minimumDisplayTime: UInt64 = 1_800_000_000  // 1.8 秒

        Task {
            // 并行：预热容器 + 最低显示时间
            async let warmup: () = warmupContainer()
            async let delay: () = Task.sleep(nanoseconds: minimumDisplayTime)

            _ = try? await warmup
            _ = try? await delay

            await MainActor.run {
                showingSplash = false
                onFinish()
            }
        }
    }

    /// 预热后端容器（fire-and-forget）
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
