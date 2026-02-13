import SwiftUI

/// 登录 / 注册视图
struct AuthView: View {
    @ObservedObject var authService: AuthService

    @State private var username = ""
    @State private var password = ""
    @State private var isRegistering = false
    @State private var isLoading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                Spacer()

                // Logo 区域
                VStack(spacing: 12) {
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 56))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    Text("ClawBowl")
                        .font(.largeTitle.bold())

                    Text("AI 智能助手")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                // 表单
                VStack(spacing: 16) {
                    TextField("用户名", text: $username)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    SecureField("密码", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(isRegistering ? .newPassword : .password)

                    if let error = errorMessage {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                            .multilineTextAlignment(.center)
                    }

                    Button(action: submit) {
                        Group {
                            if isLoading {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Text(isRegistering ? "注册" : "登录")
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(
                            LinearGradient(
                                colors: canSubmit ? [.blue, .cyan] : [.gray],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .foregroundColor(.white)
                        .font(.headline)
                        .cornerRadius(12)
                    }
                    .disabled(!canSubmit || isLoading)
                }
                .padding(.horizontal, 32)

                // 切换登录 / 注册
                Button(action: {
                    withAnimation {
                        isRegistering.toggle()
                        errorMessage = nil
                    }
                }) {
                    Text(isRegistering ? "已有账号？点击登录" : "没有账号？点击注册")
                        .font(.subheadline)
                        .foregroundColor(.blue)
                }

                Spacer()
                Spacer()
            }
            .navigationBarHidden(true)
        }
    }

    private var canSubmit: Bool {
        username.count >= 3 && password.count >= 6
    }

    private func submit() {
        guard canSubmit else { return }

        isLoading = true
        errorMessage = nil

        Task {
            do {
                if isRegistering {
                    try await authService.register(username: username, password: password)
                } else {
                    try await authService.login(username: username, password: password)
                }
            } catch {
                errorMessage = error.localizedDescription
            }
            isLoading = false
        }
    }
}

#Preview {
    AuthView(authService: AuthService.shared)
}
