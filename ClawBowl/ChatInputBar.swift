import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import UIKit

/// 底部聊天输入栏（支持图片和文件附件）
struct ChatInputBar: View {
    @Binding var text: String
    @Binding var selectedAttachment: Attachment?
    let isLoading: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool
    @State private var showImagePicker = false
    @State private var showDocumentPicker = false
    @State private var showFileTooLargeAlert = false
    @State private var rejectedFileName = ""

    /// 文件大小限制 10MB
    private let maxFileSize = 10 * 1024 * 1024

    var body: some View {
        VStack(spacing: 0) {
            // 附件预览条
            if let att = selectedAttachment {
                attachmentPreview(att)
            }

            // 输入行
            HStack(alignment: .bottom, spacing: 6) {
                // 图片选择按钮
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: selectedAttachment?.isImage == true ? "photo.fill" : "photo")
                        .font(.system(size: 20))
                        .foregroundStyle(selectedAttachment?.isImage == true ? .blue : .secondary)
                        .frame(width: 32, height: 36)
                }
                .disabled(isLoading)

                // 文件选择按钮（回形针）
                Button {
                    showDocumentPicker = true
                } label: {
                    Image(systemName: selectedAttachment != nil && !(selectedAttachment!.isImage) ? "paperclip.circle.fill" : "paperclip")
                        .font(.system(size: 20))
                        .foregroundStyle(selectedAttachment != nil && !(selectedAttachment!.isImage) ? .blue : .secondary)
                        .frame(width: 32, height: 36)
                }
                .disabled(isLoading)

                // 输入框
                TextField(isLoading ? "AI 正在处理..." : "输入消息...", text: $text, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                    .focused($isFocused)
                    .disabled(isLoading)
                    .onSubmit {
                        if canSend && !isLoading {
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
        }
        .background(.ultraThinMaterial)
        .sheet(isPresented: $showImagePicker) {
            ImagePicker(attachment: $selectedAttachment)
        }
        .sheet(isPresented: $showDocumentPicker) {
            DocumentPicker(
                attachment: $selectedAttachment,
                maxFileSize: maxFileSize,
                onFileTooLarge: { filename in
                    rejectedFileName = filename
                    showFileTooLargeAlert = true
                }
            )
        }
        .alert("文件过大", isPresented: $showFileTooLargeAlert) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text("\"\(rejectedFileName)\" 超过 10MB 限制，请选择较小的文件。")
        }
    }

    /// 附件预览条（图片缩略图 或 文件图标+文件名）
    @ViewBuilder
    private func attachmentPreview(_ att: Attachment) -> some View {
        HStack(alignment: .top, spacing: 8) {
            if att.isImage, let uiImage = UIImage(data: att.data) {
                // 图片缩略图
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 60, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                // 文件图标
                Image(systemName: fileIcon(for: att.mimeType))
                    .font(.system(size: 32))
                    .foregroundStyle(.blue)
                    .frame(width: 60, height: 60)
                    .background(Color(.systemGray5))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(att.isImage ? "已选择图片" : att.filename)
                    .font(.caption)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text(att.isImage ? "发送后将由 AI 分析" : att.formattedSize)
                    .font(.caption2)
                    .foregroundColor(.secondary.opacity(0.7))
            }

            Spacer()

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    selectedAttachment = nil
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color(.systemGray6).opacity(0.5))
    }

    /// 有文字或有附件即可发送
    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasAttachment = selectedAttachment != nil
        return (hasText || hasAttachment) && !isLoading
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

// MARK: - PHPicker 封装（图片选择器）

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var attachment: Attachment?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.selectionLimit = 1
        config.filter = .images
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let parent: ImagePicker

        init(_ parent: ImagePicker) {
            self.parent = parent
        }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            parent.dismiss()

            guard let provider = results.first?.itemProvider,
                  provider.canLoadObject(ofClass: UIImage.self) else { return }

            provider.loadObject(ofClass: UIImage.self) { object, _ in
                if let uiImage = object as? UIImage {
                    // 压缩为 JPEG
                    let maxDim: CGFloat = 512
                    var targetSize = uiImage.size
                    if max(targetSize.width, targetSize.height) > maxDim {
                        let scale = maxDim / max(targetSize.width, targetSize.height)
                        targetSize = CGSize(width: targetSize.width * scale, height: targetSize.height * scale)
                    }
                    let renderer = UIGraphicsImageRenderer(size: targetSize)
                    let resized = renderer.image { _ in
                        uiImage.draw(in: CGRect(origin: .zero, size: targetSize))
                    }
                    guard let jpegData = resized.jpegData(compressionQuality: 0.4) else { return }

                    let att = Attachment(
                        filename: "photo_\(UUID().uuidString.prefix(8)).jpg",
                        data: jpegData,
                        mimeType: "image/jpeg"
                    )
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.parent.attachment = att
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Document Picker 封装（通用文件选择器）

struct DocumentPicker: UIViewControllerRepresentable {
    @Binding var attachment: Attachment?
    let maxFileSize: Int
    var onFileTooLarge: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item])
        picker.allowsMultipleSelection = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, UIDocumentPickerDelegate {
        let parent: DocumentPicker

        init(_ parent: DocumentPicker) {
            self.parent = parent
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { return }

            // 获取安全访问权限
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }

            do {
                let data = try Data(contentsOf: url)

                // 检查文件大小
                guard data.count <= parent.maxFileSize else {
                    let filename = url.lastPathComponent
                    DispatchQueue.main.async {
                        self.parent.onFileTooLarge?(filename)
                    }
                    return
                }

                let filename = url.lastPathComponent
                let mimeType = Self.mimeType(for: url)

                let att = Attachment(
                    filename: filename,
                    data: data,
                    mimeType: mimeType
                )
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        self.parent.attachment = att
                    }
                }
            } catch {
                // 读取失败，忽略
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // 取消时不做任何操作
        }

        /// 根据文件 URL 推断 MIME type
        static func mimeType(for url: URL) -> String {
            if let utType = UTType(filenameExtension: url.pathExtension) {
                return utType.preferredMIMEType ?? "application/octet-stream"
            }
            return "application/octet-stream"
        }
    }
}

#Preview {
    VStack {
        Spacer()
        ChatInputBar(text: .constant(""), selectedAttachment: .constant(nil), isLoading: false) {}
        ChatInputBar(text: .constant(""), selectedAttachment: .constant(nil), isLoading: true) {}
    }
}
