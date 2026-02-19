import Foundation

struct CronJob: Identifiable, Codable {
    let id: String
    let name: String?
    let enabled: Bool?
    let agentId: String?
    let createdAtMs: Int64?
    let updatedAtMs: Int64?
    let schedule: CronSchedule?
    let sessionTarget: String?
    let payload: CronPayload?
    let delivery: CronDelivery?
    let state: CronState?

    struct CronSchedule: Codable {
        let kind: String?
        let expr: String?
        let tz: String?
    }

    struct CronPayload: Codable {
        let kind: String?
        let message: String?
    }

    struct CronDelivery: Codable {
        let mode: String?
    }

    struct CronState: Codable {
        let nextRunAtMs: Int64?
        let lastRunAtMs: Int64?
        let lastStatus: String?
        let lastError: String?
        let lastDurationMs: Int64?
        let consecutiveErrors: Int?
    }

    var displayName: String {
        name ?? payload?.message?.prefix(40).appending("…") as? String ?? "(未命名任务)"
    }

    var displaySchedule: String {
        guard let expr = schedule?.expr else { return "未知" }
        let tz = schedule?.tz ?? ""
        return tz.isEmpty ? expr : "\(expr) (\(tz))"
    }

    var displayMessage: String {
        payload?.message ?? "(无描述)"
    }

    var isEnabled: Bool {
        enabled ?? true
    }

    var nextRunDate: Date? {
        guard let ms = state?.nextRunAtMs else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    var lastRunDate: Date? {
        guard let ms = state?.lastRunAtMs else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }
}

actor CronService {
    static let shared = CronService()

    private let baseURL = "https://prometheusclothing.net/api/v2/cron"

    private init() {}

    func listJobs() async throws -> [CronJob] {
        guard let token = await AuthService.shared.accessToken else {
            throw CronError.notAuthenticated
        }

        guard let url = URL(string: "\(baseURL)/jobs") else {
            throw CronError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CronError.serverError
        }

        struct JobsResponse: Codable {
            let jobs: [CronJob]
        }

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(JobsResponse.self, from: data)
        return decoded.jobs
    }

    func deleteJob(id: String) async throws {
        guard let token = await AuthService.shared.accessToken else {
            throw CronError.notAuthenticated
        }

        guard let url = URL(string: "\(baseURL)/jobs/\(id)") else {
            throw CronError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (_, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CronError.serverError
        }
    }
}

enum CronError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case serverError

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "请先登录"
        case .invalidURL: return "请求地址无效"
        case .serverError: return "服务器错误"
        }
    }
}
