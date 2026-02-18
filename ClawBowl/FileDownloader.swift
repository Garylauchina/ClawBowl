import Foundation
import UIKit

/// 文件下载管理器 — 负责从后端下载 workspace 文件，支持图片缓存
actor FileDownloader {
    static let shared = FileDownloader()

    private let baseURL = "https://prometheusclothing.net/api/v2/files/download"

    /// 内存缓存：已下载的图片（key = workspace relative path）
    private var imageCache: [String: UIImage] = [:]

    /// 正在下载中的任务（防止重复请求）
    private var inFlightImages: [String: Task<UIImage?, Error>] = [:]

    private init() {}

    // MARK: - Image Download (with caching)

    /// 下载 workspace 图片，自动缓存到内存
    func downloadImage(path: String) async throws -> UIImage? {
        // Check cache first
        if let cached = imageCache[path] {
            return cached
        }

        // Check if already downloading
        if let existing = inFlightImages[path] {
            return try await existing.value
        }

        // Start new download
        let task = Task<UIImage?, Error> {
            let data = try await downloadFileData(path: path)
            guard let image = UIImage(data: data) else { return nil }
            return image
        }
        inFlightImages[path] = task

        do {
            let image = try await task.value
            inFlightImages.removeValue(forKey: path)
            if let image {
                imageCache[path] = image
            }
            return image
        } catch {
            inFlightImages.removeValue(forKey: path)
            throw error
        }
    }

    // MARK: - File Download (to temp directory for QLPreview)

    /// 下载文件到临时目录，返回本地文件 URL（供 QLPreviewController 使用）
    func downloadToTemp(path: String, filename: String) async throws -> URL {
        let data = try await downloadFileData(path: path)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clawbowl_files", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        let localURL = tempDir.appendingPathComponent(filename)
        try data.write(to: localURL)
        return localURL
    }

    // MARK: - Raw Data Download

    /// 下载文件原始数据
    func downloadFileData(path: String) async throws -> Data {
        guard let token = await AuthService.shared.accessToken else {
            throw FileDownloadError.notAuthenticated
        }

        var components = URLComponents(string: baseURL)!
        components.queryItems = [URLQueryItem(name: "path", value: path)]

        guard let url = components.url else {
            throw FileDownloadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 60

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw FileDownloadError.invalidResponse
        }

        guard http.statusCode == 200 else {
            if http.statusCode == 401 {
                throw FileDownloadError.notAuthenticated
            } else if http.statusCode == 404 {
                throw FileDownloadError.fileNotFound
            }
            throw FileDownloadError.httpError(http.statusCode)
        }

        return data
    }

    /// 构建文件下载 URL（供 MarkdownUI ImageProvider 使用）
    func buildDownloadURL(path: String) -> URL? {
        var components = URLComponents(string: baseURL)
        components?.queryItems = [URLQueryItem(name: "path", value: path)]
        return components?.url
    }

    // MARK: - Cache Management

    /// 清空图片缓存
    func clearCache() {
        imageCache.removeAll()
    }
}

/// 文件下载错误
enum FileDownloadError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case invalidResponse
    case fileNotFound
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "请先登录"
        case .invalidURL: return "无效的下载地址"
        case .invalidResponse: return "服务器响应异常"
        case .fileNotFound: return "文件不存在"
        case .httpError(let code): return "下载失败 (\(code))"
        }
    }
}
