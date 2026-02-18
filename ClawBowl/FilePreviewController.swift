import QuickLook
import SwiftUI
import UIKit

// MARK: - QLPreview (SwiftUI wrapper)

/// SwiftUI wrapper for QLPreviewController — previews any file type iOS supports
struct FilePreviewSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        let nav = UINavigationController(rootViewController: controller)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

// MARK: - Full Screen Image Viewer

/// 全屏图片查看器 — 支持双指缩放、双击缩放、拖拽返回
struct FullScreenImageViewer: View {
    let image: UIImage?
    let title: String
    @Environment(\.dismiss) private var dismiss

    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ZStack {
                    Color.black.ignoresSafeArea()

                    if let uiImage = image {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .scaleEffect(scale)
                            .offset(offset)
                            .gesture(dragGesture)
                            .gesture(magnificationGesture)
                            .onTapGesture(count: 2) {
                                withAnimation(.easeInOut(duration: 0.3)) {
                                    if scale > 1.5 {
                                        scale = 1.0
                                        lastScale = 1.0
                                        offset = .zero
                                        lastOffset = .zero
                                    } else {
                                        scale = 3.0
                                        lastScale = 3.0
                                    }
                                }
                            }
                            .frame(width: geo.size.width, height: geo.size.height)
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundStyle(.white.opacity(0.5))
                            Text("无法显示图片")
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if let uiImage = image {
                        Menu {
                            Button {
                                UIPasteboard.general.image = uiImage
                            } label: {
                                Label("复制图片", systemImage: "doc.on.doc")
                            }
                            Button {
                                UIImageWriteToSavedPhotosAlbum(uiImage, nil, nil, nil)
                            } label: {
                                Label("保存到相册", systemImage: "square.and.arrow.down")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.title3)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }

    private var magnificationGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let newScale = lastScale * value.magnification
                scale = min(max(newScale, 0.5), 5.0)
            }
            .onEnded { _ in
                withAnimation(.easeInOut(duration: 0.2)) {
                    if scale < 1.0 {
                        scale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                }
                lastScale = scale
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                if scale > 1.0 {
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                } else {
                    let verticalDrag = value.translation.height
                    if verticalDrag > 0 {
                        offset = CGSize(width: 0, height: verticalDrag)
                        let progress = min(verticalDrag / 300, 1.0)
                        scale = 1.0 - progress * 0.3
                    }
                }
            }
            .onEnded { value in
                if scale <= 1.0 {
                    if value.translation.height > 100 {
                        dismiss()
                    } else {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            offset = .zero
                            scale = 1.0
                        }
                    }
                    lastOffset = .zero
                    lastScale = 1.0
                } else {
                    lastOffset = offset
                }
            }
    }
}

// MARK: - Share Sheet (UIActivityViewController wrapper)

/// SwiftUI wrapper for UIActivityViewController — share/save files
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
