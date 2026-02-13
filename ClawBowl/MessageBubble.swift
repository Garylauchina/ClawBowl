import SwiftUI

/// 单条消息气泡视图
struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                avatarView(text: "AI", colors: [.purple, .indigo])
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // 气泡
                Text(message.content)
                    .font(.body)
                    .foregroundColor(message.role == .user ? .white : .primary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(bubbleBackground)
                    .clipShape(BubbleShape(isUser: message.role == .user))
                    .contextMenu {
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("复制", systemImage: "doc.on.doc")
                        }
                    }

                // 时间和状态
                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if message.status == .sending {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if message.status == .error {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.caption2)
                            .foregroundColor(.red)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: 280, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                avatarView(text: "我", colors: [.blue, .cyan])
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private var bubbleBackground: some View {
        if message.role == .user {
            LinearGradient(
                colors: [.blue, .cyan.opacity(0.8)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        } else {
            Color(.systemGray6)
        }
    }

    private func avatarView(text: String, colors: [Color]) -> some View {
        Text(text)
            .font(.caption.bold())
            .foregroundColor(.white)
            .frame(width: 36, height: 36)
            .background(
                LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            .clipShape(Circle())
    }
}

/// 自定义气泡形状（带尖角）
struct BubbleShape: Shape {
    let isUser: Bool

    func path(in rect: CGRect) -> Path {
        let radius: CGFloat = 16
        let tailSize: CGFloat = 6

        var path = Path()

        if isUser {
            // 用户气泡：右下角尖角
            path.addRoundedRect(
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // 右下角小尾巴
            path.move(to: CGPoint(x: rect.maxX - tailSize, y: rect.maxY - radius))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - tailSize - 8, y: rect.maxY))
        } else {
            // AI 气泡：左下角尖角
            path.addRoundedRect(
                in: CGRect(x: rect.minX + tailSize, y: rect.minY, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            // 左下角小尾巴
            path.move(to: CGPoint(x: rect.minX + tailSize, y: rect.maxY - radius))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + tailSize + 8, y: rect.maxY))
        }

        return path
    }
}

#Preview {
    VStack {
        MessageBubble(message: Message(role: .user, content: "你好！"))
        MessageBubble(message: Message(role: .assistant, content: "你好！有什么可以帮你的吗？"))
        MessageBubble(message: Message(role: .user, content: "这是一条比较长的消息，用来测试气泡的换行效果和最大宽度限制。"))
    }
    .padding()
}
