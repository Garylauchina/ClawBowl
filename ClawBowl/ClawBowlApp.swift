import SwiftUI
import UserNotifications

@main
struct ClawBowlApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var authService = AuthService.shared
    @StateObject private var startup = StartupController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            Group {
                if !startup.isReady {
                    SplashView(progress: startup.progressText)
                        .onAppear {
                            startup.beginStartup()
                        }
                } else if authService.isAuthenticated {
                    TopicListView()
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
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await ChatService.shared.reconnectIfNeeded()
                    }
                }
            }
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

@MainActor
class StartupController: ObservableObject {
    @Published var isReady = false
    @Published var progressText = "正在加载..."

    private var hasStarted = false

    func beginStartup() {
        guard !hasStarted else { return }
        hasStarted = true

        Task {
            if AuthService.shared.accessToken != nil {
                progressText = "正在启动 AI 引擎..."
                try? await AuthService.shared.refreshToken()
                await warmup()
            }
            withAnimation(.easeInOut(duration: 0.3)) { isReady = true }
        }
    }

    func ensureWarmup() {
        Task {
            let configured = await ChatService.shared.isConfigured
            guard !configured else { return }
            await warmup()
            if await ChatService.shared.isConfigured {
                NotificationCenter.default.post(name: .chatServiceReady, object: nil)
            }
        }
    }

    private func warmup() async {
        guard let token = AuthService.shared.accessToken,
              let url = URL(string: "http://106.55.174.74:8080/api/v2/chat/warmup") else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let gwURL = json["gateway_url"] as? String,
              let gwToken = json["gateway_token"] as? String,
              let sessKey = json["session_key"] as? String,
              let devId = json["device_id"] as? String,
              let devPub = json["device_public_key"] as? String,
              let devPriv = json["device_private_key"] as? String else { return }

        let gwWSURL = json["gateway_ws_url"] as? String

        await ChatService.shared.configure(
            gatewayURL: gwURL, gatewayToken: gwToken, sessionKey: sessKey,
            devicePrivateKey: devPriv, devicePublicKey: devPub, deviceId: devId,
            gatewayWSURL: gwWSURL
        )
        try? await ChatService.shared.connect()
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
            withAnimation(.easeInOut(duration: 0.8)) {
                pulseScale = 1.05
            }
        }
    }
}

// MARK: - Notifications

extension Notification.Name {
    static let chatServiceReady = Notification.Name("chatServiceReady")
}

