import SwiftUI

/// 单条消息气泡视图（支持文本、图片和文件附件）
struct MessageBubble: View {
    let message: Message

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                avatarView(text: "AI", colors: [.purple, .indigo])
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // 气泡内容
                VStack(alignment: .leading, spacing: 6) {
                    // 附件（图片缩略图 或 文件图标+文件名）
                    if let att = message.attachment {
                        if att.isImage, let uiImage = UIImage(data: att.data) {
                            Image(uiImage: uiImage)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 240, maxHeight: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else {
                            // 文件附件
                            HStack(spacing: 8) {
                                Image(systemName: fileIcon(for: att.mimeType))
                                    .font(.title2)
                                    .foregroundStyle(message.role == .user ? .white.opacity(0.9) : .blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(att.filename)
                                        .font(.caption)
                                        .foregroundColor(message.role == .user ? .white : .primary)
                                        .lineLimit(1)
                                    Text(att.formattedSize)
                                        .font(.caption2)
                                        .foregroundColor(message.role == .user ? .white.opacity(0.7) : .secondary)
                                }
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(message.role == .user ? Color.white.opacity(0.15) : Color(.systemGray5))
                            )
                        }
                    }

                    // 思考状态（浅色斜体小字，类似 Claude 的思考过程）
                    if !message.thinkingText.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "gear")
                                .font(.caption2)
                            Text(message.thinkingText)
                                .font(.caption)
                                .italic()
                        }
                        .foregroundColor(.secondary.opacity(0.7))
                    }

                    // 文本（如果有）
                    if !message.content.isEmpty {
                        Text(message.content)
                            .font(.body)
                            .foregroundColor(message.role == .user ? .white : .primary)
                    }

                    // 流式接收中：闪烁光标
                    if message.isStreaming && message.content.isEmpty && message.thinkingText.isEmpty {
                        StreamingCursor()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(BubbleShape(isUser: message.role == .user))
                .contextMenu {
                    Button {
                        UIPasteboard.general.string = message.content
                    } label: {
                        Label("复制文字", systemImage: "doc.on.doc")
                    }
                    if message.hasImage {
                        Button {
                            if let att = message.attachment,
                               att.isImage,
                               let img = UIImage(data: att.data) {
                                UIPasteboard.general.image = img
                            }
                        } label: {
                            Label("复制图片", systemImage: "photo.on.rectangle")
                        }
                    }
                }

                // 时间和状态
                HStack(spacing: 4) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if message.isStreaming {
                        ProgressView()
                            .scaleEffect(0.6)
                    } else if message.status == .sending {
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

    /// 根据 MIME type 返回合适的 SF Symbol
    private func fileIcon(for mimeType: String) -> String {
        switch mimeType {
        case let m where m.contains("pdf"):
            return "doc.richtext"
        case let m where m.contains("word") || m.contains("document"):
            return "doc.text"
        case let m where m.contains("spreadsheet") || m.contains("excel"):
            return "tablecells"
        case let m where m.contains("presentation") || m.contains("powerpoint"):
            return "rectangle.split.3x3"
        case let m where m.contains("text") || m.contains("json") || m.contains("xml") || m.contains("csv"):
            return "doc.plaintext"
        case let m where m.contains("zip") || m.contains("archive") || m.contains("compressed"):
            return "doc.zipper"
        case let m where m.contains("audio"):
            return "waveform"
        case let m where m.contains("video"):
            return "film"
        default:
            return "doc"
        }
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
            path.addRoundedRect(
                in: CGRect(x: rect.minX, y: rect.minY, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            path.move(to: CGPoint(x: rect.maxX - tailSize, y: rect.maxY - radius))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.maxX - tailSize - 8, y: rect.maxY))
        } else {
            path.addRoundedRect(
                in: CGRect(x: rect.minX + tailSize, y: rect.minY, width: rect.width - tailSize, height: rect.height),
                cornerSize: CGSize(width: radius, height: radius)
            )
            path.move(to: CGPoint(x: rect.minX + tailSize, y: rect.maxY - radius))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX + tailSize + 8, y: rect.maxY))
        }

        return path
    }
}

/// 流式接收中的闪烁光标
struct StreamingCursor: View {
    @State private var visible = true

    var body: some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.secondary.opacity(visible ? 0.6 : 0))
            .frame(width: 2, height: 16)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: visible
            )
            .onAppear { visible.toggle() }
    }
}

#Preview {
    VStack {
        MessageBubble(message: Message(role: .user, content: "你好！"))
        MessageBubble(message: Message(role: .assistant, content: "你好！有什么可以帮你的吗？"))
        MessageBubble(message: Message(
            role: .user,
            content: "请看这个文件",
            attachment: Attachment(filename: "report.pdf", data: Data(), mimeType: "application/pdf")
        ))
        MessageBubble(message: Message(
            role: .assistant,
            content: "",
            thinkingText: "正在分析图片...",
            isStreaming: true
        ))
    }
    .padding()
}
