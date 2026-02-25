# 故障排查：OpenClaw + Tavily 与「AI 服务正在启动」提示

## 现象

前端发消息后只回复：**「AI 服务正在启动，请稍后重试」**。

该文案对应前端的 `ChatError.serviceUnavailable`，通常表示：

1. **warmup 未成功**：未拿到 `gateway_url` / `session_key` 等，`ChatService` 未完成 configure
2. **WebSocket 连接失败**：configure 成功但 `connect()` 失败（握手超时、502/503、认证失败）
3. **后端 ensure_running 异常**：容器未就绪或 _wait_for_ready 超时，warmup 返回 5xx

---

## 官方文档结论：Tavily 不是内置 web search provider

根据 [OpenClaw Web Tools 官方文档](https://docs.openclaw.ai/tools/web)：

- **内置 `tools.web.search` 仅支持三种 provider**：
  - `brave`（默认）— 需 `BRAVE_API_KEY`
  - `perplexity` — 需 `PERPLEXITY_API_KEY` 或 `OPENROUTER_API_KEY`
  - `gemini` — 需 `GEMINI_API_KEY`
- **没有 `provider: "tavily"`**。若在 `openclaw.json` 里写 `tools.web.search.provider: "tavily"` 或未支持的键，可能导致：
  - 配置校验失败、Gateway 启动报错
  - 或工具加载异常，进而影响 Gateway 行为

**Tavily 在 OpenClaw 中的正确用法**：

1. **插件方式**：使用社区插件 `openclaw-tavily`，在 `plugins.entries["openclaw-tavily"]` 中配置，并通过环境变量 `TAVILY_API_KEY` 传入。
2. **Skill 方式**（当前 Tarz 做法）：不启用内置 `tools.web.search`，在 `workspace/skills/web-search/SKILL.md` 中通过 `exec` + `curl` 调用 Tavily API，由后端注入 `TAVILY_API_KEY`。

---

## 建议修复步骤

### 1. 不要用内置 web search 的 Tavily

- 在 **openclaw.json 模板** 中：
  - **不要** 设置 `tools.web.search.provider: "tavily"` 或任何非官方 provider。
  - 若需内置搜索：使用 `brave` / `perplexity` / `gemini` 之一，并配置对应 API Key。
- 若要用 Tavily，二选一：
  - **A. 插件**：安装并配置 `openclaw-tavily`（见下方示例），或  
  - **B. 保持当前方案**：`tools.web.search.enabled: false`，继续用 workspace 的 **web-search Skill**（Tavily 通过 exec+curl），环境变量 `TAVILY_API_KEY` 由后端注入。

### 2. 恢复为「已知可启动」的 openclaw.json

确保模板中 `tools.web` 与官方一致，例如：

```json
"tools": {
  "web": {
    "search": { "enabled": false },
    "fetch": { "enabled": true }
  }
}
```

- `search.enabled: false`：不使用内置 web search，避免缺少 Brave/Perplexity/Gemini key 或误配 Tavily 导致启动/运行异常。
- 搜索能力由 **workspace/skills/web-search**（Tavily + 环境变量）提供。

### 3. 若坚持用 Tavily 插件（openclaw-tavily）

在 **plugins** 中配置，而不是在 `tools.web.search` 里写 Tavily：

```json
"plugins": {
  "entries": {
    "llm-task": { "enabled": true },
    "openclaw-tavily": {
      "enabled": true,
      "config": {
        "apiKey": "${TAVILY_API_KEY}"
      }
    }
  }
}
```

并确保容器环境变量中有 `TAVILY_API_KEY`（后端 instance_manager 已支持传入）。

注意：插件需在镜像或启动流程中安装（如 `openclaw plugins install openclaw-tavily`），否则 Gateway 可能因找不到插件而启动失败。

### 4. 确认 Gateway 能就绪

- 后端用 `POST http://127.0.0.1:{port}/v1/chat/completions` 做 _wait_for_ready。
- 若 OpenClaw 升级后该路径或认证有变，可能导致「认为未就绪」或误判就绪。可查看容器日志：
  - `docker logs clawbowl-{user_id} 2>&1 | tail -100`
- 若有配置错误，日志中会有报错；修正配置后重启容器再测 warmup 与发消息。

### 5. 排查顺序小结

| 步骤 | 操作 |
|------|------|
| 1 | 检查当前实例的 openclaw.json 是否包含 `provider: "tavily"` 或非 brave/perplexity/gemini 的配置，若有则改回上述「已知可启动」配置 |
| 2 | 确认 `tools.web.search` 为 `enabled: false`，或改用 brave/perplexity/gemini 之一并配好对应 key |
| 3 | 重启容器（或通过 Backend 重启实例），观察容器日志是否有 config/plugin 相关错误 |
| 4 | 再次在 App 内执行 warmup（如重新登录或重进会话），确认能拿到 gateway_url 并建立 WebSocket |
| 5 | 若仍提示「AI 服务正在启动」，查后端 warmup 日志与 nginx 到 Gateway 的 502/503，并确认 WebSocket 握手是否因认证/路径失败 |

---

## 参考链接

- [OpenClaw Web Tools（官方）](https://docs.openclaw.ai/tools/web)  
- [OpenClaw Configuration Reference](https://docs.openclaw.ai/gateway/configuration-reference)  
- Tavily 插件（社区）：[openclaw-tavily](https://openclawdir.com/plugins/tavily-7vwo37) — 配置在 `plugins.entries["openclaw-tavily"]`，非 `tools.web.search`。
