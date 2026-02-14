import SwiftUI
import PhotosUI

/// 底部聊天输入栏（支持图片选择）
struct ChatInputBar: View {
    @Binding var text: String
    @Binding var selectedImage: UIImage?
    let isLoading: Bool
    let onSend: () -> Void

    @FocusState private var isFocused: Bool
    @State private var photosPickerItem: PhotosPickerItem?

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
                            photosPickerItem = nil
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
                PhotosPicker(selection: $photosPickerItem, matching: .images) {
                    Image(systemName: selectedImage != nil ? "photo.fill" : "photo")
                        .font(.system(size: 22))
                        .foregroundStyle(selectedImage != nil ? .blue : .secondary)
                        .frame(width: 36, height: 36)
                }
                .disabled(isLoading)
                .onChange(of: photosPickerItem) { _ in
                    loadImage()
                }

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
    }

    /// 有文字或有图片即可发送
    private var canSend: Bool {
        let hasText = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasImage = selectedImage != nil
        return (hasText || hasImage) && !isLoading
    }

    /// 从 PhotosPicker 加载图片
    private func loadImage() {
        guard let item = photosPickerItem else { return }
        Task {
            if let data = try? await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selectedImage = uiImage
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
