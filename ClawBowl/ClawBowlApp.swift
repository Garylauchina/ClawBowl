import SwiftUI

@main
struct ClawBowlApp: App {
    @StateObject private var authService = AuthService.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if authService.isAuthenticated {
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
