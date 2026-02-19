import Foundation

struct CronJob: Identifiable {
    let id: String
    let name: String?
    let enabled: Bool
    let schedule: String?
    let timezone: String?
    let message: String?
    let lastStatus: String?
    let lastError: String?
    let nextRunAtMs: Int?
    let lastRunAtMs: Int?

    var displayName: String {
        if let n = name, !n.isEmpty { return n }
        if let m = message { return String(m.prefix(40)) }
        return "(unnamed)"
    }

    var displaySchedule: String {
        guard let s = schedule else { return "unknown" }
        if let tz = timezone, !tz.isEmpty { return s + " (" + tz + ")" }
        return s
    }

    var displayMessage: String { message ?? "" }

    var nextRunDate: Date? {
        guard let ms = nextRunAtMs else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    var lastRunDate: Date? {
        guard let ms = lastRunAtMs else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    static func from(_ d: [String: Any]) -> CronJob? {
        guard let id = d["id"] as? String else { return nil }
        let sched = d["schedule"] as? [String: Any]
        let payload = d["payload"] as? [String: Any]
        let state = d["state"] as? [String: Any]
        return CronJob(
            id: id,
            name: d["name"] as? String,
            enabled: d["enabled"] as? Bool ?? true,
            schedule: sched?["expr"] as? String,
            timezone: sched?["tz"] as? String,
            message: payload?["message"] as? String,
            lastStatus: state?["lastStatus"] as? String,
            lastError: state?["lastError"] as? String,
            nextRunAtMs: (state?["nextRunAtMs"] as? NSNumber)?.intValue,
            lastRunAtMs: (state?["lastRunAtMs"] as? NSNumber)?.intValue
        )
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
        guard let url = URL(string: baseURL + "/jobs") else {
            throw CronError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw CronError.serverError("No response")
        }
        guard httpResponse.statusCode == 200 else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw CronError.serverError("HTTP \(httpResponse.statusCode): \(body)")
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = json["jobs"] as? [[String: Any]] else {
            let preview = String(data: data.prefix(300), encoding: .utf8) ?? "(binary)"
            throw CronError.serverError("Bad format: " + preview)
        }

        return arr.compactMap { CronJob.from($0) }
    }

    func deleteJob(id: String) async throws {
        guard let token = await AuthService.shared.accessToken else {
            throw CronError.notAuthenticated
        }
        guard let url = URL(string: baseURL + "/jobs/" + id) else {
            throw CronError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw CronError.serverError("Delete failed: \(body)")
        }
    }
}

enum CronError: LocalizedError {
    case notAuthenticated
    case invalidURL
    case serverError(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated: return "Please log in"
        case .invalidURL: return "Invalid URL"
        case .serverError(let msg): return msg
        }
    }
}
