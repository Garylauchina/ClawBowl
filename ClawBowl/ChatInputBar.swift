import SwiftUI
import PhotosUI

/// 底部聊天输入栏（支持图片选择）
struct ChatInputBar: View {
    @Binding var text: String
    @Binding var selectedImage: UIImage?
    let isLoading: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool
    @State private var showImagePicker = false

    var body: some View {
        VStack(spacing: 0) {
            // 图片预览条
            if let image = selectedImage {
                HStack(alignment: .top, spacing: 8) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 60, height: 60)
                        .clipShape(RoundedRectangle(cornerRadius: 8))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("已选择图片")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("发送后将由 AI 分析")
                            .font(.caption2)
                            .foregroundColor(.secondary.opacity(0.7))
                    }

                    Spacer()

                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedImage = nil
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

            // 输入行
            HStack(alignment: .bottom, spacing: 8) {
                // 图片选择按钮
                Button {
                    showImagePicker = true
                } label: {
                    Image(systemName: selectedImage != nil ? "photo.fill" : "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(selectedImage != nil ? .blue : .secondary)
                        .frame(width: 36, height: 36)
                }
                .disabled(isLoading)

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
            ImagePicker(image: $selectedImage)
        }
    }

    /// 有文字或有图片即可发送
    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = selectedImage != nil
        return (hasText || hasImage) && !isLoading
    }
}

// MARK: - PHPicker 封装（带"添加"按钮的标准图片选择器）

struct ImagePicker: UIViewControllerRepresentable {
    @Binding var image: UIImage?
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
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            self.parent.image = uiImage
                        }
                    }
                }
            }
        }
    }
}

#Preview {
    VStack {
        Spacer()
        ChatInputBar(text: .constant(""), selectedImage: .constant(nil), isLoading: false) {}
        ChatInputBar(text: .constant(""), selectedImage: .constant(nil), isLoading: true) {}
    }
}
