import SwiftUI
import UserNotifications

@main
struct ClawBowlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authService = AuthService.shared
    @StateObject private var startup = StartupController()

    var body: some Scene {
        WindowGroup {
            Group {
                if !startup.isReady {
                    SplashView(progress: startup.progressText)
                        .onAppear {
                            startup.beginStartup()
                        }
                } else if authService.isAuthenticated {
                    ChatView()
                        .environmentObject(authService)
                        .onAppear {
                            NotificationManager.shared.requestPermission()
                            startup.ensureWarmup()
                        }
                } else {
                    AuthView(authService: authService)
                }
            }
            .animation(.easeInOut, value: authService.isAuthenticated)
        }
    }
}

// MARK: - AppDelegate for APNs callbacks

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        _ = NotificationManager.shared
        return true
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        NotificationManager.shared.handleDeviceToken(deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        NotificationManager.shared.handleRegistrationError(error)
    }
}

// MARK: - Startup Controller

/// 启动控制器：管理后端初始化流程，将进度反馈给前端
@MainActor
class StartupController: ObservableObject {
    @Published var isReady = false
    @Published var progressText = "正在加载..."

    private var hasStarted = false

    /// 由 SplashView.onAppear 调用 — 欢迎屏已经显示后才开始后端工作
    func beginStartup() {
        guard !hasStarted else { return }
        hasStarted = true

        Task {
            // ① 检查登录状态
            progressText = "正在检查登录状态..."
            await smallDelay(0.3)

            let hasToken = AuthService.shared.accessToken != nil

            if hasToken {
                // ② 刷新 Token
                progressText = "正在验证身份..."
                await refreshTokenQuiet()

                // ③ 预热容器
                progressText = "正在启动 AI 引擎..."
                await warmupContainerQuiet()

                // ④ 准备聊天服务
                progressText = "正在准备聊天服务..."
                await smallDelay(0.3)
            } else {
                // 未登录，跳过后端预热
                progressText = "准备登录界面..."
                await smallDelay(0.5)
            }

            // ⑤ 完成
            progressText = "准备就绪！"
            await smallDelay(0.4)

            withAnimation(.easeInOut(duration: 0.3)) {
                isReady = true
            }
        }
    }

    // MARK: - Private

    /// 刷新 Token（2 秒超时，失败静默跳过）
    private func refreshTokenQuiet() async {
        await withTimeLimit(seconds: 2) {
            try? await AuthService.shared.refreshToken()
        }
    }

    /// ChatView 出现时调用——若 ChatService 尚未配置，补发 warmup 并通知
    func ensureWarmup() {
        Task {
            let configured = await ChatService.shared.isConfigured
            guard !configured else { return }
            await warmupContainerQuiet()
            let nowConfigured = await ChatService.shared.isConfigured
            if nowConfigured {
                NotificationCenter.default.post(name: .chatServiceReady, object: nil)
            }
        }
    }

    /// 预热后端容器，获取 Gateway + 设备认证信息，建立 WebSocket 连接
    private func warmupContainerQuiet() async {
        guard let token = AuthService.shared.accessToken,
              let url = URL(string: "https://prometheusclothing.net/api/v2/chat/warmup") else {
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        await withTimeLimit(seconds: 15) {
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let gwURL = json["gateway_url"] as? String,
                  let gwToken = json["gateway_token"] as? String,
                  let sessKey = json["session_key"] as? String,
                  let devId = json["device_id"] as? String,
                  let devPub = json["device_public_key"] as? String,
                  let devPriv = json["device_private_key"] as? String else {
                return
            }
            await ChatService.shared.configure(
                gatewayURL: gwURL,
                gatewayToken: gwToken,
                sessionKey: sessKey,
                devicePrivateKey: devPriv,
                devicePublicKey: devPub,
                deviceId: devId
            )
            try? await ChatService.shared.connect()
        }
    }

    /// 执行一个异步操作，但最多等待指定秒数
    private func withTimeLimit(seconds: Double, operation: @escaping () async -> Void) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await operation() }
            group.addTask { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            // 第一个完成的就返回（操作完成或超时）
            await group.next()
            group.cancelAll()
        }
    }

    private func smallDelay(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

// MARK: - Splash View（纯显示，不包含任何业务逻辑）

struct SplashView: View {
    let progress: String

    @State private var logoScale: CGFloat = 0.85
    @State private var pulseScale: CGFloat = 1.0

    private static let tips = [
        "正在唤醒你的 AI 助手",
        "连接数字灵魂中",
        "准备好了吗？让我们开始吧",
        "AI 正在热身",
        "数字世界的大门正在开启",
        "你的 AI 助手已经等不及了",
        "灵魂上线中",
        "正在同步记忆",
    ]

    private let tip = tips.randomElement() ?? ""

    var body: some View {
        ZStack {
            Color(red: 0.05, green: 0.05, blue: 0.15)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer()

                // Logo
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.blue, .cyan, .teal],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .scaleEffect(logoScale * pulseScale)

                // 标题
                Text("ClawBowl")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(.white)

                // 随机趣味语
                if !tip.isEmpty {
                    Text(tip)
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.top, 4)
                }

                Spacer()

                // ── 后端进度反馈 ──
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white.opacity(0.5)))
                        .scaleEffect(0.8)

                    Text(progress)
                        .font(.caption)
                        .foregroundColor(.white.opacity(0.6))
                }
                .frame(height: 24)

                Spacer()
                    .frame(height: 50)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.6)) {
                logoScale = 1.0
            }
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulseScale = 1.05
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let chatServiceReady = Notification.Name("chatServiceReady")
}

