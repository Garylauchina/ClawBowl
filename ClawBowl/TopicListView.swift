import SwiftUI

/// 会话（话题）列表：按 sessionKey 管理，点击进入单会话聊天
struct TopicListView: View {
    @EnvironmentObject private var authService: AuthService
    @State private var sessionKeys: [String] = []
    @State private var selectedTopic: TopicItem?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newTopic()
                    } label: {
                        Label("新话题", systemImage: "plus.bubble")
                    }
                }
                Section("最近会话") {
                    ForEach(sessionKeys, id: \.self) { key in
                        Button {
                            selectedTopic = TopicItem(sessionKey: key)
                        } label: {
                            HStack {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .foregroundColor(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(displayTitle(for: key))
                                        .font(.body)
                                        .foregroundColor(.primary)
                                    Text(key)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("话题")
            .onAppear { refreshSessionKeys() }
            .navigationDestination(item: $selectedTopic) { item in
                ChatScreen(sessionKey: item.sessionKey)
                    .environmentObject(authService)
            }
        }
    }

    private func displayTitle(for sessionKey: String) -> String {
        if sessionKey.hasPrefix("clawbowl-") {
            return "默认对话"
        }
        if sessionKey.hasPrefix("ios:") {
            return "新对话"
        }
        return sessionKey
    }

    private func newTopic() {
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        let ts = Int(Date().timeIntervalSince1970 * 1000)
        let key = "ios:\(deviceId):\(ts)"
        sessionKeys.insert(key, at: 0)
        selectedTopic = TopicItem(sessionKey: key)
    }

    private func refreshSessionKeys() {
        Task {
            var keys = SessionStore.listCachedSessionKeys()
            let current = await ChatService.shared.effectiveSessionKey
            if let c = current, !keys.contains(c) {
                keys.insert(c, at: 0)
            }
            await MainActor.run { sessionKeys = keys }
        }
    }
}

struct TopicItem: Identifiable, Hashable {
    let sessionKey: String
    var id: String { sessionKey }
}
