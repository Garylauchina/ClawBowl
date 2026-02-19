import SwiftUI

struct CronView: View {
    @State private var jobs: [CronJob] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("加载定时任务…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.largeTitle)
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.body)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        Button("重试") {
                            Task { await loadJobs() }
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if jobs.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "clock.badge.questionmark")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary.opacity(0.5))
                        Text("暂无定时任务")
                            .font(.headline)
                            .foregroundColor(.secondary)
                        Text("通过对话让 AI 创建定时任务\n例如：每天早上9点提醒我查收邮件")
                            .font(.subheadline)
                            .foregroundColor(.secondary.opacity(0.7))
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(jobs) { job in
                            CronJobRow(job: job)
                        }
                        .onDelete(perform: deleteJobs)
                    }
                    .listStyle(.insetGrouped)
                    .refreshable {
                        await loadJobs()
                    }
                }
            }
            .navigationTitle("定时任务")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                        .font(.subheadline)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task { await loadJobs() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.subheadline)
                    }
                    .disabled(isLoading)
                }
            }
        }
        .task {
            await loadJobs()
        }
    }

    private func loadJobs() async {
        isLoading = true
        errorMessage = nil
        do {
            jobs = try await CronService.shared.listJobs()
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func deleteJobs(at offsets: IndexSet) {
        let toDelete = offsets.map { jobs[$0] }
        Task {
            for job in toDelete {
                try? await CronService.shared.deleteJob(id: job.id)
            }
            await loadJobs()
        }
    }
}

private struct CronJobRow: View {
    let job: CronJob

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(job.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Spacer()
                if !job.isEnabled {
                    Text("已暂停")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray, in: Capsule())
                }
            }

            if job.displayMessage != job.displayName {
                Text(job.displayMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Label(job.displaySchedule, systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.blue)

                if let status = job.state?.lastStatus {
                    Label(
                        statusText(status),
                        systemImage: statusIcon(status)
                    )
                    .font(.caption)
                    .foregroundColor(statusColor(status))
                }
            }

            if let next = job.nextRunDate {
                let formatted = Self.timeFormatter.string(from: next)
                Text("下次执行: " + formatted)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func statusText(_ status: String) -> String {
        switch status {
        case "ok", "success": return "成功"
        case "error": return "出错"
        case "running": return "运行中"
        default: return status
        }
    }

    private func statusIcon(_ status: String) -> String {
        switch status {
        case "ok", "success": return "checkmark.circle"
        case "error": return "xmark.circle"
        case "running": return "arrow.triangle.2.circlepath"
        default: return "questionmark.circle"
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status {
        case "ok", "success": return .green
        case "error": return .red
        case "running": return .orange
        default: return .secondary
        }
    }
}

#Preview {
    CronView()
}
