import SwiftUI
import UIKit

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
                    SplashView {
                        withAnimation(.easeInOut(duration: 0.35)) {
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
            .animation(.easeInOut(duration: 0.35), value: splashDone)
            .animation(.easeInOut, value: authService.isAuthenticated)
        }
    }
}

// MARK: - Splash View

/// 启动欢迎屏：Logo + 随机趣味提示语
/// 核心职责：在展示期间完成 **所有** 后台初始化，确保进入聊天界面后零卡顿。
struct SplashView: View {
    let onFinish: () -> Void

    @State private var logoScale: CGFloat = 0.85
    @State private var pulseScale: CGFloat = 1.0
    @State private var dotCount = 0
    @State private var timerRef: Timer?
    @State private var statusText = ""

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

            // 趣味提示 + 加载点
            Text(tip + String(repeating: ".", count: dotCount))
                .font(.subheadline)
                .foregroundColor(.white.opacity(0.6))
                .frame(height: 20)

            Spacer()
                .frame(height: 60)
        }
        .onAppear {
            startAnimations()
            performAllStartupWork()
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

    // MARK: - 启动期间完成所有初始化

    /// 在 Splash 显示期间，按顺序完成所有后台准备工作。
    /// 所有任务完成 + 最低显示时间后，才调用 onFinish 进入主界面。
    private func performAllStartupWork() {
        let minimumDisplayNanos: UInt64 = 2_500_000_000  // 2.5 秒

        Task {
            // ① 最低显示时间（与后续任务并行计时）
            async let minDelay: () = Task.sleep(nanoseconds: minimumDisplayNanos)

            // ② Token 刷新（如果已登录）→ 确保后续 API 调用不会 401
            async let tokenWork: () = refreshTokenIfNeeded()

            // ③ 预热键盘（iOS 首次键盘弹出有 ~300ms 延迟）
            async let keyboardWork: () = preWarmKeyboard()

            // 等待 token 刷新完成
            _ = try? await tokenWork

            // ④ Token 刷新后，再预热容器（需要有效 token）
            await warmupContainer()

            // ⑤ 预触发 ChatService 单例初始化
            _ = ChatService.shared

            // 等待最低显示时间和键盘预热
            _ = try? await minDelay
            _ = try? await keyboardWork

            await MainActor.run {
                onFinish()
            }
        }
    }

    /// 刷新 JWT token（如果已登录且 token 可能过期）
    private func refreshTokenIfNeeded() async {
        guard AuthService.shared.accessToken != nil else { return }
        try? await AuthService.shared.refreshToken()
    }

    /// 预热后端容器（调用 warmup 端点触发 Docker 容器启动）
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

    /// 预热 iOS 键盘子系统
    /// iOS 第一次弹出键盘时需要加载键盘进程（~200-400ms），
    /// 在 splash 期间提前触发可以消除进入聊天后的首次输入卡顿。
    private func preWarmKeyboard() async {
        await MainActor.run {
            let window = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first?.windows.first

            let tempField = UITextField(frame: .zero)
            tempField.autocorrectionType = .no
            window?.addSubview(tempField)
            tempField.becomeFirstResponder()
            tempField.resignFirstResponder()
            tempField.removeFromSuperview()
        }
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
