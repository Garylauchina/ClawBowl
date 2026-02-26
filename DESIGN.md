# ClawBowl 系统设计文档

> **项目代号**：ClawBowl | **产品名**：Tarz
> **版本**：2.0 | **更新日期**：2026-02-25
> **描述**：面向普通用户的托管式 AI Agent 平台

---

## 1. 系统概述

### 1.1 产品定位

Tarz 是一个**托管式 AI Agent 平台**，基于 OpenClaw 开源框架构建。每个用户拥有独立、常驻的 AI 分身，支持多模态交互、长期记忆和自动化任务。

**核心理念**：极简前端 + 智能后端。用户只需一个聊天窗口，所有复杂性由后端处理。

### 1.2 核心目标

| 目标 | 描述 |
|------|------|
| 独立分身 | 每个用户拥有独立运行的 OpenClaw 实例 |
| 多模态交互 | 支持文本、文件、图片、语音输入 |
| 长期记忆 | 持久化存储，Agent 越用越聪明 |
| 零门槛 | 用户无需理解部署、服务器、API 等技术细节 |

---

## 2. 总体架构

### 2.1 架构图

```
┌─────────────────────────────────────────────────────────────────────────┐
│                           iOS App (ClawBowl)                          │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐  │
│  │  ChatView   │  │ ChatService │  │MessageStore │  │ FileCardView│  │
│  └─────────────┘  └─────────────┘  └─────────────┘  └─────────────┘  │
└─────────────────────────────────────────────────────────────────────────┘
                                      │
                    ┌─────────────────┴─────────────────┐
                    │                                   │
          ┌─────────▼──────────┐            ┌─────────▼──────────┐
          │  warmup / upload   │            │  WebSocket 直连    │
          │   (HTTPS → Backend)│            │  (Gateway 直连)    │
          └─────────┬──────────┘            └─────────┬──────────┘
                    │                                   │
                    ▼                                   ▼
┌───────────────────────────────────────────────────────────────────────┐
│                         Backend (FastAPI)                              │
│  ┌────────────┐  ┌────────────┐  ┌────────────┐  ┌────────────┐  │
│  │  auth.py   │  │instance_mgr│  │chat_router │  │file_router │  │
│  └────────────┘  └────────────┘  └────────────┘  └────────────┘  │
└───────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌───────────────────────────────────────────────────────────────────────┐
│                        nginx 反向代理                                  │
│         /api/* → Backend    |    /gw/{port}/* → Gateway            │
└───────────────────────────────────────────────────────────────────────┘
                    │
                    ▼
┌───────────────────────────────────────────────────────────────────────┐
│                 OpenClaw Gateway (Docker 容器)                        │
│  ┌─────────────────────────────────────────────────────────────┐      │
│  │  Agent Loop │ Memory │ Tools (exec/read/write/browser) │     │      │
│  │  Cron │ Heartbeat │ Skills │ Web Search (Tavily)         │      │
│  └─────────────────────────────────────────────────────────────┘      │
│                              │                                        │
│              ┌───────────────┴───────────────┐                      │
│              │     bind mount (持久化)        │                      │
│              │  /config + /workspace         │                      │
│              └───────────────────────────────┘                      │
└───────────────────────────────────────────────────────────────────────┘
```

### 2.2 控制面 vs 执行面

| 层面 | 职责 | 不负责 |
|------|------|--------|
| **控制面** (Backend) | 用户认证、JWT、实例生命周期管理、warmup 凭证下发、附件上传、APNs 推送 | 聊天消息路由、对话内容存储 |
| **执行面** (OpenClaw) | 对话处理、工具执行、记忆管理、任务自动化 | 用户认证、账单管理 |

### 2.3 架构原则

**宿主机是服务者，不是控制者**：

1. 对话数据路径不经过 Backend（iOS ↔ WebSocket ↔ Gateway）
2. 唯一权威数据源：容器内 JSONL 文件
3. Backend 仅通过 HTTP API 与容器交互（warmup 时读取端口/token）
4. 零侵入：不禁入修改 OpenClaw 管理的文件

---

## 3. 核心概念

### 3.1 数字灵魂（Soul）

每个用户的"数字灵魂"由以下文件构成：

| 纳入版本化 | 不纳入版本化 |
|------------|--------------|
| `openclaw.json` (配置) | `workspace/media/` (临时媒体) |
| `agents/{id}/sessions/` (会话记录) | `workspace/canvas/` (Canvas 文件) |
| `workspace/AGENTS.md` (行为规则) | `logs/` (调试日志) |
| `workspace/SOUL.md` (人格) | `cache/` (缓存) |
| `workspace/USER.md` (用户画像) | |
| `workspace/MEMORY.md` (长期记忆) | |
| `workspace/skills/` (自定义技能) | |

### 3.2 数据目录结构

**宿主机侧**：
```
/var/lib/clawbowl/{user_id}/
├── config/                    # → 容器 /data/config
│   ├── openclaw.json          # 运行时配置
│   ├── agents/                # Agent 状态和会话
│   ├── cron/                  # 定时任务
│   └── devices/               # 设备配对凭证
└── workspace/                 # → 容器 /data/workspace
    ├── AGENTS.md
    ├── SOUL.md
    ├── USER.md
    ├── MEMORY.md
    ├── skills/
    └── media/inbound/         # 附件上传目录
```

---

## 4. 技术栈

| 层级 | 技术 |
|------|------|
| iOS 客户端 | SwiftUI + WebSocket (URLSessionWebSocketTask) + MessageStore + Ed25519 (CryptoKit) |
| 后端服务 | Python FastAPI + SQLAlchemy + Docker SDK |
| 对话通道 | iOS → WebSocket → nginx → Gateway |
| 执行引擎 | OpenClaw Gateway (Node.js) + Docker |
| 反向代理 | Nginx + Cloudflare |
| LLM | DeepSeek V3.2 / GLM-4.6V Flash (via ZenMux) |
| 搜索 API | Tavily |
| 数据库 | SQLite |
| 认证 | JWT + Ed25519 设备密钥 |
| 推送 | APNs (HTTP/2 + JWT) |

---

## 5. 功能模块

### 5.1 用户注册与实例创建

**流程**：

```
1. 用户在 iOS App 注册/登录
         ↓
2. Backend 创建用户记录 (SQLite)
         ↓
3. instance_manager 分配端口 (19001+)
         ↓
4. 生成 gateway_token (secrets.token_hex(24))
         ↓
5. config_generator 渲染 openclaw.json 模板
         ↓
6. _init_workspace 渲染 workspace 模板
         ↓
7. docker.containers.run() 启动容器
         ↓
8. 健康检查 → 返回凭证
```

**关键代码**：`backend/app/services/instance_manager.py`

### 5.2 通信协议

#### 5.2.1 Warmup 端点

**端点**：`POST /api/v2/chat/warmup`

**返回**：
```json
{
  "status": "warm",
  "gateway_url": "/gw/19002",
  "gateway_ws_url": "ws://IP:PORT/gw/19002/",
  "gateway_token": "...",
  "session_key": "clawbowl-{user_id}",
  "device_id": "...",
  "device_public_key": "...",
  "device_private_key": "..."
}
```

#### 5.2.2 WebSocket 协议

iOS App 与 Gateway 使用 OpenClaw 原生 WebSocket 协议：

| 消息类型 | 方向 | 描述 |
|----------|------|------|
| `connect.challenge` | Gateway → iOS | 认证挑战 |
| `connect` | iOS → Gateway | Ed25519 签名响应 |
| `hello-ok` | Gateway → iOS | 认证成功 |
| `chat.send` | iOS → Gateway | 发送消息 |
| `chat.history` | iOS → Gateway | 加载历史 |
| `chat.abort` | iOS → Gateway | 取消对话 |
| `agent` | Gateway → iOS | 推理过程流 |
| `chat` | Gateway → iOS | 回复内容流 |

### 5.3 对话持久化

| 层级 | 存储位置 | 说明 |
|------|----------|------|
| **权威数据源** | 容器 `agents/main/sessions/*.jsonl` | OpenClaw 写入 |
| **iOS 本地缓存** | MessageStore (SQLite) | 离线可用 |
| **恢复机制** | WebSocket `chat.history` | 登录时同步 |

**原则**：Backend 不存储对话内容，数据管理完全交给 Agent/实例。

### 5.4 附件上传

**端点**：`POST /api/v2/files/upload`

**流程**：
```
iOS (multipart) → Backend → workspace/media/inbound/{uuid}_{filename}
                      ↓
                返回路径给 iOS
                      ↓
                消息中引用路径
```

### 5.5 预设模板

**模板目录**：`backend/templates/`

| 模板 | 用途 | 变量 |
|------|------|------|
| `workspace/AGENTS.md.j2` | Agent 行为规则 | USER_NAME, AGENT_NAME |
| `workspace/SOUL.md.j2` | 人格定义 | AGENT_NAME |
| `workspace/USER.md.j2` | 用户画像 | USER_NAME |
| `workspace/MEMORY.md.j2` | 长期记忆 | - |
| `workspace/skills/web-search/SKILL.md.j2` | 搜索技能 | TAVILY_API_KEY |

---

## 6. OpenClaw 功能状态

### 6.1 已验证功能 (35 项)

| 类别 | 功能 | 状态 |
|------|------|------|
| 文件操作 | read / write / edit / exec | ✅ |
| 视觉 | image (GLM-4.6V Flash) | ✅ |
| 搜索 | web_search (Tavily) | ✅ |
| 网页 | web_fetch | ✅ |
| 浏览器 | browser (Chromium + CDP) | ✅ |
| 自动化 | cron / heartbeat | ✅ |
| 记忆 | memory_search / memory_get | ✅ |
| 会话 | sessions_list / history / send / spawn | ✅ |
| 技能 | SKILL.md 注入 | ✅ |
| 插件 | llm-task | ✅ |

### 6.2 受限功能

| 功能 | 状态 | 说明 |
|------|------|------|
| Tailscale | ❌ | 容器内无 TUN 设备 |
| Canvas | ⏳ | 需 OpenClaw iOS App 作为 node |
| Nodes | ⏳ | 同上 |

---

## 7. 安全设计

### 7.1 当前安全措施

| 层级 | 措施 |
|------|------|
| 容器隔离 | Docker namespace (进程/网络/文件系统) |
| 资源限制 | cgroup (内存 2GB, CPU 1核) |
| 网络隔离 | 端口仅映射到 127.0.0.1 |
| 数据持久化 | bind mount 到 /var/lib/clawbowl/ |
| 认证 | JWT (Backend) + Ed25519 (Gateway) |
| 文件安全 | 路径穿越防护 (is_relative_to) |

### 7.2 密钥管理

| 密钥 | 用途 | 生成方式 |
|------|------|----------|
| JWT | Backend API 认证 | secrets.token_hex(32) |
| gateway_token | Gateway 认证 | secrets.token_hex(24) |
| Ed25519 | iOS 设备配对 | cryptography.hazmat.primitives.asymmetric.ed25519 |

---

## 8. 部署与运维

### 8.1 Docker 配置

**关键配置**：

| 参数 | 值 | 说明 |
|------|-----|------|
| 镜像 | clawbowl-openclaw:latest | 自定义构建 |
| 端口映射 | 18789 → 19001+ | 动态端口分配 |
| 内存限制 | 2GB | cgroup 限制 |
| CPU 限制 | 1核 | cgroup 限制 |
| 重启策略 | unless-stopped | 崩溃自动恢复 |
| init | tini | 僵尸进程回收 |

### 8.2 容器启动参数

```bash
docker run -d \
  --name clawbowl-{user_id} \
  -p 127.0.0.1:{port}:18789 \
  -v /var/lib/clawbowl/{user_id}/config:/data/config:rw \
  -v /var/lib/clawbowl/{user_id}/workspace:/data/workspace:rw \
  -v /usr/lib/node_modules/openclaw:/usr/lib/node_modules/openclaw:ro \
  -e NODE_OPTIONS="--max-old-space-size=4096" \
  -e OPENCLAW_STATE_DIR=/data/config \
  -e TAVILY_API_KEY="{key}" \
  --restart unless-stopped \
  --memory=2g \
  --cpus=1 \
  --init \
  clawbowl-openclaw:latest
```

### 8.3 健康检查

| 检查项 | 方式 | 间隔 |
|--------|------|------|
| 容器状态 | docker ps | 实时 |
| Gateway 健康 | curl /healthz | 1分钟 |
| 进程存活 | ps aux | 1分钟 |

---

## 9. 已知问题与限制

### 9.1 容器限制

| 限制项 | 原因 | 替代方案 |
|--------|------|----------|
| Tailscale | 无 TUN 设备 | Nginx + Cloudflare 反代 |
| VPN 组网 | 同上 | 不支持 |
| 任意端口 | 仅映射 Gateway 端口 | 按需添加映射 |

### 9.2 模型限制

| 问题 | 说明 | 缓解措施 |
|------|------|----------|
| apply_patch | 仅 OpenAI 模型支持 | 使用 exec 替代 |
| LLM 工具误解 | 免费模型训练数据不含 OpenClaw | TOOLS.md 显式标注 |

---

## 10. 未来规划

### Phase 2: 单用户功能完善

| 任务 | 描述 |
|------|------|
| 多模型路由 | ZenMux 智能路由：简单→免费，复杂→旗舰 |
| 人格增强 | SOUL.md 深度定制 |
| 语义嵌入 | 中文 embedding 集成 |

### Phase 3: 多用户扩展

| 任务 | 描述 |
|------|------|
| 容器编排 | Docker Compose |
| 订阅分级 | Free/Pro/Premium 模板 + 资源配额 |
| 多端客户端 | Android + Web |

### Phase 4: 模块替换

| 模块 | 自建难度 | 说明 |
|------|----------|------|
| System Prompt | 低 | 100 行 |
| 工具系统 | 低 | 500 行 |
| Agent Loop | 中 | 800 行 |
| 会话管理 | 中 | 500 行 |

---

## 附录 A: 文件索引

| 文件 | 描述 |
|------|------|
| `backend/app/services/instance_manager.py` | 容器生命周期管理 |
| `backend/app/services/config_generator.py` | 配置生成 |
| `backend/app/routers/chat_router.py` | warmup 端点 |
| `backend/app/routers/file_router.py` | 附件上传/下载 |
| `backend/app/auth.py` | JWT 认证 |
| `ClawBowl/ChatService.swift` | WebSocket 客户端 |
| `ClawBowl/ChatViewModel.swift` | 聊天业务逻辑 |
| `ClawBowl/Message.swift` | 消息模型 |
| `ClawBowl/MessageBubble.swift` | 消息气泡（助手用 StreamChatAI 流式 Markdown） |

**iOS 依赖**：[Swift Markdown UI](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.0、[StreamChatAI](https://github.com/GetStream/stream-chat-swift-ai) 0.4.0。须保持 MarkdownUI 为 2.4.0 以与 StreamChatAI 的 exact 依赖一致。

---

## 附录 B: API 端点

| 端点 | 方法 | 描述 |
|------|------|------|
| `/api/v2/chat/warmup` | POST | 预热，返回 Gateway 凭证 |
| `/api/v2/chat/history` | POST | 获取历史消息 |
| `/api/v2/files/upload` | POST | 附件上传 |
| `/api/v2/files/download` | GET | 文件下载 |
| `/api/v2/cron/jobs` | GET/POST | Cron 任务管理 |
| `/api/v2/instance/status` | GET | 实例状态 |
| `/api/v2/instance/restart` | POST | 重启实例 |

---

## 附录 C: 配置模板

### openclaw.json 结构

```json
{
  "meta": { "last touched version": "2026.2.23" },
  "gateway": {
    "port": 18789,
    "bind": "loopback"
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "deepseek/deepseek-chat",
        "fallbacks": ["z-ai/glm-4.6v-flash-free"]
      }
    }
  },
  "tools": {
    "web": {
      "search": { "enabled": false },
      "fetch": { "enabled": true }
    }
  }
}
```

**重要**：OpenClaw 官方内置 `tools.web.search` 仅支持 **Brave / Perplexity / Gemini**，**不支持** `provider: "tavily"`。Tarz 的联网搜索通过 **workspace/skills/web-search**（Skill + 环境变量 `TAVILY_API_KEY`）实现，因此保持 `search.enabled: false`。若改为 `true` 且未配置上述三者之一，可能导致启动或运行异常。详见 `docs/TROUBLESHOOTING-OPENCLAW-TAVILY.md`。

---

## 附录 D: 历史消息加载（Telegram 式）

| 行为 | 实现 |
|------|------|
| **首屏** | 冷启动 / 重新登录后，首屏以服务端为准：`POST /api/v2/chat/history` 不传 `before`，返回最新一页（如 100 条），前端**替换**本地列表。 |
| **加载更早** | 上滑或顶部区域出现时请求 `before=oldestTimestamp`，服务端返回更早一页，前端 **prepend** 并保持滚动位置（`scrollAnchorAfterPrepend`）。 |
| **下拉刷新** | 下拉触发重新拉取首屏并**合并**新消息，不替换已有。 |
| **空列表** | 首屏返回空时展示「暂无消息，发一句开始对话」；本地仅持久化最近 N 条作离线兜底。 |

后端分页：`limit`（默认 100）、`before`（毫秒时间戳，取比其更早的消息），返回 `messages`、`hasMore`、`oldestTimestamp`。每条带稳定 `id`（如 `l{line_idx}`）供前端列表 id 与锚点使用。

---

*文档版本：2.0 | 最后更新：2026-02-25*
