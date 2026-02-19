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
                            NavigationLink(destination: CronJobDetailView(job: job)) {
                                CronJobRow(job: job)
                            }
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
                if !job.enabled {
                    Text("已暂停")
                        .font(.caption2)
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.gray, in: Capsule())
                }
            }

            if !job.displayMessage.isEmpty, job.displayMessage != job.displayName {
                Text(job.displayMessage)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Label(job.displaySchedule, systemImage: "clock")
                    .font(.caption)
                    .foregroundColor(.blue)

                if let status = job.lastStatus {
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

// MARK: - Cron Job Detail View

private struct CronJobDetailView: View {
    let job: CronJob

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        f.locale = Locale(identifier: "zh_CN")
        return f
    }()

    var body: some View {
        List {
            Section("基本信息") {
                row("任务名称", job.displayName)
                row("状态", job.enabled ? "已启用" : "已暂停")
            }

            Section("调度") {
                row("Cron 表达式", job.schedule ?? "未知")
                if let tz = job.timezone, !tz.isEmpty {
                    row("时区", tz)
                }
                if let next = job.nextRunDate {
                    row("下次执行", Self.dateFormatter.string(from: next))
                }
                if let last = job.lastRunDate {
                    row("上次执行", Self.dateFormatter.string(from: last))
                }
            }

            if let msg = job.message, !msg.isEmpty {
                Section("任务指令") {
                    Text(msg)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }

            if let status = job.lastStatus {
                Section("执行状态") {
                    row("状态", statusLabel(status))
                    if let err = job.lastError, !err.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("错误信息")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text(err)
                                .font(.callout)
                                .foregroundColor(.red)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("任务详情")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "ok", "success": return "成功"
        case "error": return "出错"
        case "running": return "运行中"
        default: return status
        }
    }
}

#Preview {
    CronView()
}
