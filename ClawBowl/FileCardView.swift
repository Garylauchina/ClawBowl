import SwiftUI

/// Agent 生成的文件展示组件 — 图片内联展示，其他文件显示为卡片
struct FileCardView: View {
    let file: FileInfo

    @State private var downloadedImage: UIImage?
    @State private var isLoadingImage = false
    @State private var previewURL: URL?
    @State private var showPreview = false
    @State private var showShare = false
    @State private var isDownloading = false
    @State private var downloadError: String?

    var body: some View {
        if file.isImage {
            imageView
        } else {
            fileCardView
        }
    }

    // MARK: - Image (inline display)

    @ViewBuilder
    private var imageView: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let image = downloadedImage {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 280, maxHeight: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .onTapGesture { downloadForPreview() }
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
            } else if isLoadingImage {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray5))
                    .frame(width: 160, height: 120)
                    .overlay {
                        ProgressView()
                    }
            } else {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(.systemGray5))
                    .frame(width: 160, height: 120)
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
                    .onTapGesture { loadImage() }
            }

            if let error = downloadError {
                Text(error)
                    .font(.caption2)
                    .foregroundColor(.red)
            }
        }
        .task { loadImage() }
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

            if isDownloading {
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
    }

    // MARK: - Download Actions

    private func loadImage() {
        guard downloadedImage == nil, !isLoadingImage else { return }
        isLoadingImage = true
        downloadError = nil

        Task {
            do {
                let image = try await FileDownloader.shared.downloadImage(path: file.path)
                await MainActor.run {
                    downloadedImage = image
                    isLoadingImage = false
                }
            } catch {
                await MainActor.run {
                    isLoadingImage = false
                    downloadError = "加载失败"
                }
            }
        }
    }

    private func downloadForPreview() {
        guard !isDownloading else { return }

        if previewURL != nil {
            showPreview = true
            return
        }

        isDownloading = true
        Task {
            do {
                let url = try await FileDownloader.shared.downloadToTemp(
                    path: file.path, filename: file.name
                )
                await MainActor.run {
                    previewURL = url
                    isDownloading = false
                    showPreview = true
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadError = "下载失败"
                }
            }
        }
    }

    private func downloadForShare() {
        guard !isDownloading else { return }

        if previewURL != nil {
            showShare = true
            return
        }

        isDownloading = true
        Task {
            do {
                let url = try await FileDownloader.shared.downloadToTemp(
                    path: file.path, filename: file.name
                )
                await MainActor.run {
                    previewURL = url
                    isDownloading = false
                    showShare = true
                }
            } catch {
                await MainActor.run {
                    isDownloading = false
                    downloadError = "下载失败"
                }
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
