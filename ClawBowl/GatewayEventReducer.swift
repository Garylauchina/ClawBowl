import Foundation

// MARK: - Reducer 输出（对 UI 的增量操作）

enum GatewayUIAction: Sendable {
    /// 追加用户消息（发送时由 ViewModel 先 append，此处可选用于服务端回显）
    case appendUser(text: String, attachmentLabel: String?)
    /// 更新当前流式助手消息正文（增量或全量差量）
    case updateAssistantContent(delta: String)
    /// 助手思考/工具状态
    case updateAssistantThinking(text: String)
    /// 助手生成的文件
    case appendAssistantFile(name: String, path: String, size: Int, mimeType: String, inlineData: String?)
    /// 流结束（正常或中断）
    case finish(interrupted: Bool)
    /// 错误结束（如断线，partial 表示可能有部分内容）
    case errorFinish(partial: Bool)
}

// MARK: - 统一事件收敛器（单会话隔离 + 单 run 隔离 + seq 幂等 + 单源正文）

actor GatewayEventReducer {
    private let currentSessionKey: String
    private var activeRunId: String?
    private var lastSeqByRunStream: [String: Int] = [:]
    private var doneReceived = false
    private var streamContentBuffer = ""

    init(currentSessionKey: String) {
        self.currentSessionKey = currentSessionKey
    }

    /// 重置 run 状态（切换会话或重新发送时调用）
    func resetRun() {
        activeRunId = nil
        lastSeqByRunStream.removeAll()
        doneReceived = false
        streamContentBuffer = ""
    }

    /// 处理 event 帧，返回应应用的 UI 操作（空数组表示丢弃或无需更新）
    func reduce(event: String, payload: [String: Any]) -> [GatewayUIAction] {
        if event == "chat" || event.hasPrefix("chat.") {
            return reduceChat(payload: payload)
        }
        if event == "agent" || event.hasPrefix("agent.") {
            return reduceAgent(payload: payload, eventName: event)
        }
        return []
    }

    /// 断线时调用，输出 errorFinish
    func disconnect() -> [GatewayUIAction] {
        guard !doneReceived else { return [] }
        doneReceived = true
        return [.errorFinish(partial: !streamContentBuffer.isEmpty)]
    }

    // MARK: - Chat（仅兜底 / 最终态，默认不写正文）

    private func reduceChat(payload: [String: Any]) -> [GatewayUIAction] {
        guard payload["sessionKey"] as? String == currentSessionKey || (payload["sessionKey"] == nil && currentSessionKey.isEmpty == false) else {
            return []
        }
        let state = payload["state"] as? String ?? ""
        let message = payload["message"] as? [String: Any] ?? [:]
        if state == "final" {
            doneReceived = true
            let text = Self.extractText(from: message["content"])
            if !text.isEmpty {
                return [.updateAssistantContent(delta: text), .finish(interrupted: false)]
            }
            return [.finish(interrupted: false)]
        }
        if state == "delta" || state.isEmpty {
            let text = Self.extractText(from: message["content"])
            if text.isEmpty, let t = payload["content"] as? String { return [.updateAssistantContent(delta: t)] }
            if text.isEmpty, let t = payload["delta"] as? String { return [.updateAssistantContent(delta: t)] }
            if !text.isEmpty { return [.updateAssistantContent(delta: text)] }
        }
        return []
    }

    // MARK: - Agent（正文单源：只消费 event=="agent" && stream=="assistant"）

    private func reduceAgent(payload: [String: Any], eventName: String) -> [GatewayUIAction] {
        let runId = payload["runId"] as? String ?? (payload["data"] as? [String: Any])?["runId"] as? String
        let seqRaw = payload["seq"] ?? (payload["data"] as? [String: Any])?["seq"]
        let seq: Int? = (seqRaw as? Int) ?? (seqRaw as? Double).map { Int($0) }

        if let rid = runId, activeRunId == nil {
            activeRunId = rid
        }
        if let rid = runId, let active = activeRunId, rid != active {
            return []
        }

        let stream = payload["stream"] as? String ?? ""
        let streamKey = "\(runId ?? "")_\(stream)"
        if let s = seq {
            let last = lastSeqByRunStream[streamKey] ?? -1
            if s <= last { return [] }
            lastSeqByRunStream[streamKey] = s
        }

        var data = payload["data"] as? [String: Any] ?? [:]
        if data.isEmpty, payload["delta"] != nil || payload["content"] != nil {
            data = ["delta": payload["delta"] ?? payload["content"] ?? ""]
        }

        switch stream {
        case "assistant", "":
            if eventName != "agent" { return [] }
            let delta = (data["delta"] as? String) ?? (data["content"] as? String) ?? ""
            if delta.isEmpty { return [] }
            let diff = Self.chunkDiff(newChunk: delta, existing: streamContentBuffer)
            streamContentBuffer = streamContentBuffer + diff
            if diff.isEmpty { return [] }
            return [.updateAssistantContent(delta: diff)]

        case "tool":
            if let name = data["name"] as? String, !name.isEmpty {
                let status = Self.toolStatus(name)
                return [.updateAssistantThinking(text: status)]
            }
            return []

        case "lifecycle":
            let phase = data["phase"] as? String ?? ""
            if phase == "end", !doneReceived {
                if runId == nil || runId == activeRunId {
                    doneReceived = true
                    return [.finish(interrupted: false)]
                }
            }
            return []

        default:
            return []
        }
    }

    private static func extractText(from msgContent: Any?) -> String {
        guard let msgContent = msgContent else { return "" }
        if let arr = msgContent as? [[String: Any]] {
            return arr.compactMap { p -> String? in
                guard p["type"] as? String == "text" else { return nil }
                return p["text"] as? String
            }.joined()
        }
        if let s = msgContent as? String { return s }
        return ""
    }

    /// prefix-diff + overlap 去重，返回应追加的差量
    private static func chunkDiff(newChunk: String, existing: String) -> String {
        if newChunk.count > existing.count, newChunk.hasPrefix(existing) {
            return String(newChunk.dropFirst(existing.count))
        }
        if newChunk == existing || existing.hasSuffix(newChunk) {
            return ""
        }
        return newChunk
    }

    private static func toolStatus(_ name: String) -> String {
        let map: [String: String] = [
            "image": "正在分析图片...",
            "web_search": "正在搜索网页...",
            "web_fetch": "正在读取网页...",
            "read": "正在读取文件...",
            "write": "正在写入文件...",
            "edit": "正在编辑文件...",
            "exec": "正在执行命令...",
            "process": "正在处理任务...",
            "cron": "正在设置定时任务...",
            "memory": "正在检索记忆...",
        ]
        return map[name] ?? "正在执行 \(name)..."
    }
}
