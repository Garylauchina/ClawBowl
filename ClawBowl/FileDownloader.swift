import Foundation
import UIKit

/// 文件下载管理器 — 负责从后端下载 workspace 文件，支持图片缓存
actor FileDownloader {
    static let shared = FileDownloader()

    private let endpoint = "https://prometheusclothing.net/api/v2/files/download"

    private var imageCache: [String: UIImage] = [:]
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

    /// 通过 POST 下载文件数据（绕过 CDN 对 GET 请求的拦截）
    func downloadFileData(path: String) async throws -> Data {
        guard let url = URL(string: endpoint) else {
            throw FileDownloadError.invalidURL
        }

        for attempt in 0..<2 {
            guard let token = await AuthService.shared.accessToken else {
                throw FileDownloadError.notAuthenticated
            }

            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 60

            let body: [String: String] = ["path": path, "token": token]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let http = response as? HTTPURLResponse else {
                throw FileDownloadError.invalidResponse
            }

            if http.statusCode == 200 {
                let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? ""
                if contentType.contains("text/html") {
                    throw FileDownloadError.blockedByProxy
                }
                return data
            }

            if http.statusCode == 401 && attempt == 0 {
                try? await AuthService.shared.refreshToken()
                continue
            }

            if http.statusCode == 401 {
                throw FileDownloadError.notAuthenticated
            } else if http.statusCode == 404 {
                throw FileDownloadError.fileNotFound
            }
            throw FileDownloadError.httpError(http.statusCode)
        }
        throw FileDownloadError.notAuthenticated
    }

    // MARK: - Cache Management

    /// 手动缓存图片
    func cacheImage(_ image: UIImage, forPath path: String) {
        imageCache[path] = image
    }

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
    case blockedByProxy
    case httpError(Int)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "请先登录"
        case .invalidURL: return "无效的下载地址"
        case .invalidResponse: return "服务器响应异常"
        case .fileNotFound: return "文件不存在"
        case .blockedByProxy: return "CDN 拦截，请重试"
        case .httpError(let code): return "下载失败 (\(code))"
        }
    }
}
