import SwiftUI

/// 底部聊天输入栏
struct ChatInputBar: View {
    @Binding var text: String
    let isLoading: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            // 输入框
            TextField(isLoading ? "AI 正在思考..." : "输入消息...", text: $text, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(.systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($isFocused)
                .disabled(isLoading)
                .onSubmit {
                    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading {
                        onSend()
                    }
                }

            // 发送按钮
            Button(action: onSend) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(canSend ? .blue : .gray.opacity(0.4))
            }
            .disabled(!canSend)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }
}

#Preview {
    VStack {
        Spacer()
        ChatInputBar(text: .constant("你好"), isLoading: false) {}
        ChatInputBar(text: .constant(""), isLoading: true) {}
    }
}
