import Foundation

/// Cron job management API service
actor CronService {
    static let shared = CronService()

    private let baseURL = "https://prometheusclothing.net/api/v2/cron"

    private init() {}

    /// Fetch all cron jobs for the current user
    func listJobs() async throws -> String {
        guard let token = await AuthService.shared.accessToken else {
            throw CronError.notAuthenticated
        }

        guard let url = URL(string: "\(baseURL)/jobs") else {
            throw CronError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw CronError.serverError
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let jobs = json["jobs"] as? String else {
            return "No cron jobs configured"
        }

        return jobs
    }

    /// Delete a cron job by ID
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
        case .notAuthenticated: return "Please log in first"
        case .invalidURL: return "Invalid request URL"
        case .serverError: return "Server error"
        }
    }
}
