import SwiftUI

/// Agent 生成的文件展示组件 — 图片内联展示缩略图，其他文件显示为卡片
///
/// `lazyImage = true` 时图片也显示为紧凑卡片，点击后再下载并全屏查看。
/// 用于单条消息包含大量图片的场景，避免同时发起几十个下载请求。
struct FileCardView: View {
    let file: FileInfo
    var lazyImage: Bool = false

    @State private var downloadedImage: UIImage?
    @State private var loadPhase: LoadPhase = .idle
    @State private var previewURL: URL?
    @State private var showPreview = false
    @State private var showShare = false
    @State private var showFullScreen = false
    @State private var downloadError: String?

    private enum LoadPhase {
        case idle, loading, loaded, failed
    }

    var body: some View {
        if file.isImage && !lazyImage {
            imageView
        } else if file.isImage && lazyImage {
            lazyImageCardView
        } else {
            fileCardView
        }
    }

    // MARK: - Image (inline thumbnail + tap for fullscreen)

    @ViewBuilder
    private var imageView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                switch loadPhase {
                case .loaded:
                    if let image = downloadedImage {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 260, maxHeight: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .contentShape(Rectangle())
                            .onTapGesture { showFullScreen = true }
                            .contextMenu {
                                Button {
                                    UIPasteboard.general.image = image
                                } label: {
                                    Label("复制图片", systemImage: "doc.on.doc")
                                }
                                Button { downloadForShare() } label: {
                                    Label("保存到手机", systemImage: "square.and.arrow.down")
                                }
                            }
                    }

                case .loading:
                    thumbnailPlaceholder(showSpinner: true)

                case .failed:
                    thumbnailPlaceholder(showSpinner: false)
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title3)
                                    .foregroundStyle(.secondary)
                                Text("加载失败，点击重试")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .onTapGesture { loadPhase = .idle }

                case .idle:
                    thumbnailPlaceholder(showSpinner: false)
                        .overlay {
                            VStack(spacing: 4) {
                                Image(systemName: "photo")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text(file.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                }
            }

            Text("\(file.name) · \(file.formattedSize)")
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
        }
        .task(id: file.path) {
            await loadImageAsync()
        }
        .onAppear {
            if downloadedImage == nil, loadPhase != .loading {
                Task { await loadImageAsync() }
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenImageViewer(image: downloadedImage, title: file.name)
        }
        .sheet(isPresented: $showShare) {
            if let url = previewURL {
                ShareSheet(items: [url])
            }
        }
    }

    private func thumbnailPlaceholder(showSpinner: Bool) -> some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color(.systemGray5))
            .frame(width: 160, height: 120)
            .overlay {
                if showSpinner {
                    ProgressView()
                }
            }
    }

    // MARK: - File Card (non-image)

    private var fileCardView: some View {
        HStack(spacing: 10) {
            Image(systemName: fileIcon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(file.formattedSize) · \(fileTypeLabel)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            if loadPhase == .loading {
                ProgressView()
                    .scaleEffect(0.8)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
        )
        .onTapGesture { downloadForPreview() }
        .contextMenu {
            Button { downloadForPreview() } label: {
                Label("预览", systemImage: "eye")
            }
            Button { downloadForShare() } label: {
                Label("保存到手机", systemImage: "square.and.arrow.down")
            }
        }
        .sheet(isPresented: $showPreview) {
            if let url = previewURL {
                FilePreviewSheet(url: url)
            }
        }
        .sheet(isPresented: $showShare) {
            if let url = previewURL {
                ShareSheet(items: [url])
            }
        }
        .alert("下载失败", isPresented: .init(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    // MARK: - Lazy Image Card (compact, tap-to-load)

    private var lazyImageCardView: some View {
        HStack(spacing: 10) {
            Group {
                if loadPhase == .loaded, let img = downloadedImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(.systemGray5))
                        .frame(width: 44, height: 44)
                        .overlay {
                            if loadPhase == .loading {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Image(systemName: "photo")
                                    .foregroundStyle(.secondary)
                            }
                        }
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(file.name)
                    .font(.callout)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Text("\(file.formattedSize) · 点击查看")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(.systemGray6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(.systemGray4), lineWidth: 0.5)
        )
        .onTapGesture { loadAndShowFullScreen() }
        .contextMenu {
            Button { loadAndShowFullScreen() } label: {
                Label("查看图片", systemImage: "eye")
            }
            Button { downloadForShare() } label: {
                Label("保存到手机", systemImage: "square.and.arrow.down")
            }
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            FullScreenImageViewer(image: downloadedImage, title: file.name)
        }
        .sheet(isPresented: $showShare) {
            if let url = previewURL {
                ShareSheet(items: [url])
            }
        }
        .alert("下载失败", isPresented: .init(
            get: { downloadError != nil },
            set: { if !$0 { downloadError = nil } }
        )) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
    }

    private func loadAndShowFullScreen() {
        guard loadPhase != .loading else { return }

        if downloadedImage != nil {
            showFullScreen = true
            return
        }

        loadPhase = .loading
        Task {
            do {
                let data = try await FileDownloader.shared.downloadFileData(path: file.path)
                if let image = UIImage(data: data) {
                    await FileDownloader.shared.cacheImage(image, forPath: file.path)
                    downloadedImage = image
                    loadPhase = .loaded
                    showFullScreen = true
                } else {
                    loadPhase = .failed
                    downloadError = "无法解析图片"
                }
            } catch {
                loadPhase = .failed
                downloadError = error.localizedDescription
            }
        }
    }

    // MARK: - Async Image Loading

    private func loadImageAsync() async {
        guard loadPhase != .loaded else { return }
        loadPhase = .loading

        if let b64 = file.inlineData, !b64.isEmpty {
            if let rawData = Data(base64Encoded: b64), let image = UIImage(data: rawData) {
                await FileDownloader.shared.cacheImage(image, forPath: file.path)
                downloadedImage = image
                loadPhase = .loaded
                return
            }
        }

        for attempt in 1...3 {
            loadPhase = .loading
            do {
                let data = try await FileDownloader.shared.downloadFileData(path: file.path)
                if let image = UIImage(data: data) {
                    await FileDownloader.shared.cacheImage(image, forPath: file.path)
                    downloadedImage = image
                    loadPhase = .loaded
                    return
                } else {
                    loadPhase = .failed
                }
            } catch {
                loadPhase = .failed
            }

            guard attempt < 3 else { break }
            try? await Task.sleep(nanoseconds: UInt64(attempt) * 1_500_000_000)
            if Task.isCancelled { return }
        }
    }

    // MARK: - Download Actions

    private func downloadForPreview() {
        guard loadPhase != .loading else { return }

        if previewURL != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                showPreview = true
            }
            return
        }

        loadPhase = .loading
        Task {
            do {
                let url = try await FileDownloader.shared.downloadToTemp(
                    path: file.path, filename: file.name
                )
                previewURL = url
                loadPhase = .idle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showPreview = true
                }
            } catch {
                loadPhase = .failed
                downloadError = error.localizedDescription
            }
        }
    }

    private func downloadForShare() {
        guard loadPhase != .loading else { return }

        if previewURL != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                showShare = true
            }
            return
        }

        loadPhase = .loading
        Task {
            do {
                let url = try await FileDownloader.shared.downloadToTemp(
                    path: file.path, filename: file.name
                )
                previewURL = url
                loadPhase = .idle
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    showShare = true
                }
            } catch {
                loadPhase = .failed
                downloadError = error.localizedDescription
            }
        }
    }

    // MARK: - File Type Helpers

    private var fileIcon: String {
        let mime = file.mimeType.lowercased()
        if mime.contains("pdf") { return "doc.richtext" }
        if mime.contains("word") || mime.contains("document") { return "doc.text" }
        if mime.contains("spreadsheet") || mime.contains("excel") { return "tablecells" }
        if mime.contains("presentation") || mime.contains("powerpoint") { return "rectangle.split.3x3" }
        if mime.contains("text") || mime.contains("json") || mime.contains("xml") || mime.contains("csv") { return "doc.plaintext" }
        if mime.contains("zip") || mime.contains("archive") || mime.contains("compressed") { return "doc.zipper" }
        if mime.contains("audio") { return "waveform" }
        if mime.contains("video") { return "film" }
        if mime.contains("image") { return "photo" }
        return "doc"
    }

    private var fileTypeLabel: String {
        let ext = (file.name as NSString).pathExtension.uppercased()
        if ext.isEmpty { return "文件" }
        return "\(ext) 文件"
    }

}
