import MarkdownUI
import StreamChatAI
import SwiftUI

/// 单条消息气泡视图（支持 Markdown 富文本、图片、文件附件和 Agent 生成文件）
struct MessageBubble: View {
    let message: Message
    var onQuoteReply: ((Message) -> Void)?
    @State private var decodedAttachmentImage: UIImage?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            if message.role == .assistant {
                avatarView(text: "AI", colors: [.purple, .indigo])
            }

            VStack(alignment: message.role == .user ? .trailing : .leading, spacing: 4) {
                // 气泡内容
                VStack(alignment: .leading, spacing: 6) {
                    // 用户发送的附件（图片缩略图 或 文件图标+文件名）
                    if let att = message.attachment {
                        if att.isImage {
                            if let img = decodedAttachmentImage {
                                Image(uiImage: img)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(maxWidth: 240, maxHeight: 240)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            } else {
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.systemGray5))
                                    .frame(width: 160, height: 120)
                                    .overlay { ProgressView() }
                            }
                        } else {
                            userAttachmentView(att)
                        }
                    }

                    // 思考过程（浅色斜体小字）
                    if !message.thinkingText.isEmpty {
                        thinkingSection
                    }

                    // 文本内容：助手用 StreamChatAI 流式 Markdown
                    if message.role == .assistant {
                        if !message.content.isEmpty || message.isStreaming {
                            StreamingMessageView(content: message.content, isGenerating: message.isStreaming)
                        }
                        if message.isStreaming && message.content.isEmpty && message.thinkingText.isEmpty {
                            AITypingIndicatorView(text: "生成中...")
                        }
                    } else if !message.content.isEmpty {
                        Text(message.content)
                            .font(.body)
                            .foregroundColor(.white)
                    }

                    // Agent 生成的文件
                    if !message.files.isEmpty {
                        filesSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(bubbleBackground)
                .clipShape(BubbleShape(isUser: message.role == .user))
                .contextMenu {
                    if !message.content.isEmpty {
                        Button {
                            UIPasteboard.general.string = message.content
                        } label: {
                            Label("复制文字", systemImage: "doc.on.doc")
                        }
                    }
                    if message.hasImage {
                        Button {
                            if let img = decodedAttachmentImage {
                                UIPasteboard.general.image = img
                            }
                        } label: {
                            Label("复制图片", systemImage: "photo.on.rectangle")
                        }
                    }
                    Button {
                        onQuoteReply?(message)
                    } label: {
                        Label("引用回复", systemImage: "arrowshape.turn.up.left")
                    }
                }

                // 时间和状态
                HStack(spacing: 3) {
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    if message.role == .user {
                        statusIndicator
                    } else if message.isStreaming {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
                }
                .padding(.horizontal, 4)
            }
            .frame(maxWidth: message.hasFiles ? 300 : 280, alignment: message.role == .user ? .trailing : .leading)

            if message.role == .user {
                avatarView(text: "我", colors: [.blue, .cyan])
            }
        }
        .frame(maxWidth: .infinity, alignment: message.role == .user ? .trailing : .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .task(id: message.attachment?.filename) {
            guard let att = message.attachment, att.isImage, decodedAttachmentImage == nil else { return }
            let data = att.data
            decodedAttachmentImage = await Task.detached(priority: .userInitiated) {
                UIImage(data: data)
            }.value
        }
    }

    // MARK: - Thinking Section

    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: message.isStreaming ? "gear" : "checkmark.circle")
                    .font(.caption2)
                Text(message.isStreaming ? "思考中..." : "处理过程")
                    .font(.caption2)
                    .bold()
            }
            .foregroundColor(.secondary.opacity(0.6))

            ScrollView {
                Text(message.thinkingText)
                    .font(.caption)
                    .italic()
                    .foregroundColor(.secondary.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 150)
        }
    }

    // MARK: - Files Section (Agent-generated files)

    /// Auto-load threshold: images beyond this count show as compact cards
    private static let imageAutoLoadLimit = 3

    private var filesSection: some View {
        let imageCount = message.files.filter(\.isImage).count
        let useLazyMode = imageCount > Self.imageAutoLoadLimit

        return VStack(alignment: .leading, spacing: 6) {
            ForEach(message.files) { file in
                FileCardView(file: file, lazyImage: useLazyMode)
            }
        }
    }

    // MARK: - User Attachment (non-image)

    private func userAttachmentView(_ att: Attachment) -> some View {
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

    // MARK: - Status Indicator (Telegram-style)

    @ViewBuilder
    private var statusIndicator: some View {
        switch message.status {
        case .sending:
            Image(systemName: "clock")
                .font(.system(size: 9))
                .foregroundColor(.secondary.opacity(0.6))
        case .sent:
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundColor(message.role == .user ? .white.opacity(0.7) : .blue)
        case .error:
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10))
                .foregroundColor(.red)
        case .filtered:
            Image(systemName: "eye.slash")
                .font(.system(size: 10))
                .foregroundColor(.orange)
        }
    }

    // MARK: - Helpers

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

// MARK: - MarkdownUI Theme for Assistant Messages

extension MarkdownUI.Theme {
    /// ClawBowl assistant 气泡内的 Markdown 主题
    static let clawBowlAssistant = Theme()
        .text {
            ForegroundColor(.primary)
            FontSize(16)
        }
        .code {
            FontFamily(.system(.monospaced))
            FontSize(.em(0.88))
            BackgroundColor(Color(.systemGray5))
        }
        .link {
            ForegroundColor(.blue)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(20)
                }
                .markdownMargin(top: 12, bottom: 6)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(18)
                }
                .markdownMargin(top: 10, bottom: 4)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .markdownMargin(top: 8, bottom: 4)
        }
        .blockquote { configuration in
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                configuration.label
                    .markdownTextStyle {
                        ForegroundColor(.secondary)
                        FontStyle(.italic)
                    }
                    .padding(.leading, 8)
            }
            .markdownMargin(top: 4, bottom: 4)
        }
        .listItem { configuration in
            configuration.label
                .markdownMargin(top: 2, bottom: 2)
        }
}

// MARK: - Bubble Shape

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

#Preview {
    VStack {
        MessageBubble(message: Message(role: .user, content: "你好！"))
        MessageBubble(message: Message(role: .assistant, content: "你好！**有什么**可以帮你的吗？\n\n```python\nprint('hello')\n```"))
        MessageBubble(message: Message(
            role: .user,
            content: "请看这个文件",
            attachment: Attachment(filename: "report.pdf", data: Data(), mimeType: "application/pdf")
        ))
        MessageBubble(message: Message(
            role: .assistant,
            content: "报告已生成",
            files: [FileInfo(name: "report.pdf", path: "output/report.pdf", size: 245760, mimeType: "application/pdf")]
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

// MARK: - Quoted Reply Preview (embedded in MessageBubble)

extension Message {
    var quotePreview: String {
        let text = content.isEmpty ? (attachment?.isImage == true ? "[图片]" : "[文件]") : content
        if text.count > 60 {
            return String(text.prefix(60)) + "…"
        }
        return text
    }
}
