# ClawBowl 系统设计文档（V2）

> 最后更新：2026-02-14

---

## 1. 设计目标

ClawBowl 是一个面向普通用户的托管式 OpenClaw 运行平台。

核心目标：

1. 每个用户拥有一个独立、常驻的 OpenClaw 实例
2. 支持多模态输入（文本 / 文件 / 图片 / 音频）
3. 支持技能与长期记忆
4. 支持订阅分级（Free / Pro / Premium）
5. 支持：
   - 定期备份
   - 崩溃恢复
   - 容器升级
   - 回滚
   - 重置到出厂状态
6. 用户不需要理解部署、Docker、模型 API 等技术细节

---

## 2. 总体架构

系统分为两层：

### 2.1 控制面（Control Plane）

**负责**：
- 用户注册与订阅
- Runtime 生命周期管理
- 版本库（Snapshot）管理
- 备份与恢复
- 容器调度与升级
- API 路由
- 文件中转（接收 → 存入 inbox → 发引用消息）
- 会话历史 API（从容器读取，支持分页）

**不负责**：
- 文档解析 / OCR / 文件理解
- 模型调用细节
- Agent 推理逻辑

### 2.2 执行面（Execution Plane）

每个用户一个独立容器，容器内运行：
- OpenClaw runtime（Gateway 模式）
- cron / heartbeat 自动化
- 用户技能
- 用户记忆
- 工具链（文件、Shell、浏览器、网页搜索等）
- 多模态文件处理（image 工具、media understanding）

容器对用户而言是"数字灵魂"的载体。

---

## 3. 核心概念：数字灵魂（Soul）

每个 Runtime 的"灵魂"由以下内容构成：

**纳入版本化**：
```
openclaw.json                    # 配置（模型、工具、权限）
agents/{agentId}/sessions/       # 会话记录
workspace/AGENTS.md              # Agent 行为规则
workspace/SOUL.md                # 人格与边界
workspace/USER.md                # 用户画像
workspace/IDENTITY.md            # Agent 身份
workspace/MEMORY.md              # 长期记忆
workspace/memory/YYYY-MM-DD.md   # 日记忆
workspace/skills/                # 自定义技能
```

**不纳入版本化**：
```
workspace/media/                 # 临时媒体文件
workspace/canvas/                # Canvas UI 文件
logs/                            # 调试日志
cache/                           # 临时缓存
```

> Soul 范围可后续根据用户反馈调整。V1 先按"宽定义"做全量 Snapshot，后续可加 exclude 规则。

---

## 4. 容器内目录结构

遵循 OpenClaw 默认布局（`$HOME/.openclaw/`），确保所有内置工具完全兼容：

```
/root/.openclaw/                  # OPENCLAW_STATE_DIR
  openclaw.json                   # 配置文件
  agents/main/sessions/           # 会话记录
  agents/main/agent/              # Agent 状态
  canvas/                         # Canvas 资源
  cron/                           # 定时任务状态
  workspace/                      # Agent 工作空间
    AGENTS.md
    SOUL.md
    USER.md
    IDENTITY.md
    MEMORY.md
    memory/
    skills/
    media/inbound/                # 多模态文件 inbox
```

### 宿主机挂载映射

```
宿主机                                              容器内
/var/lib/clawbowl/runtimes/{rid}/soul/         →   /root/.openclaw/
/var/lib/clawbowl/runtimes/{rid}/workspace/    →   /root/.openclaw/workspace
```

---

## 5. 权威存储结构（宿主机）

```
/var/lib/clawbowl/runtimes/<rid>/
  runtime.json                    # Runtime 元数据
  snapshots/
    000001/
      soul.tar.zst               # 灵魂压缩包
      manifest.json              # 版本清单
    000002/
      ...
  soul/                           # 当前工作副本（挂载到容器）
  workspace/                      # 工作空间（挂载到容器）
  locks/                          # 操作锁
```

---

## 6. Snapshot 版本系统

### 6.1 Snapshot 定义

每个 Snapshot 是：
- 灵魂目录的压缩包（zstd）
- 带递增版本号
- 带 SHA-256 校验
- 带来源说明

### 6.2 manifest 示例

```json
{
  "rid": "uuid",
  "snap_id": "000012",
  "created_at": "2026-02-14T12:00:00Z",
  "source": "template|periodic|upgrade|crash|manual",
  "tier": "free",
  "openclaw_version": "2026.2.12",
  "hash": "sha256:..."
}
```

---

## 7. 生命周期管理

### 7.1 新用户注册

1. 选择模板（free/pro）
2. 生成 runtime_id
3. 创建 Snapshot#000001（从模板）
4. 启动容器
5. 注入 Snapshot
6. 运行健康检查

### 7.2 定期备份

| 级别 | 频率 | 保留数量 |
|------|------|---------|
| Free | 每 24 小时 | 3 个 |
| Pro | 每 5 分钟 | 30 个 |
| Premium | 每 1 分钟 | 无限 |

流程：
1. 从宿主机挂载目录直接打包 soul（无需进入容器）
2. 生成 Snapshot
3. 更新 runtime.json

### 7.3 容器崩溃恢复

1. 停止崩溃容器
2. 选择最近成功 Snapshot
3. 启动新容器
4. 注入 Snapshot
5. 健康检查
6. 失败则回退到上一个 Snapshot

### 7.4 容器升级（蓝绿部署）

1. 强制 Checkpoint
2. 拉取新镜像
3. 使用最近 Snapshot 启动新容器（green）
4. 健康检查通过 → 切流量
5. 停止旧容器
6. 失败则回滚

### 7.5 容器重置

**Soft Reset**：
- 指向 Snapshot#000001
- 不删除历史

**Factory Reset**：
- 删除所有 Snapshots
- 重建模板 Snapshot
- 重启容器

---

## 8. 多模态输入策略

### 8.1 原则

控制面（Orchestrator）只负责文件中转，不负责理解。

### 8.2 流程

1. iOS 发送含图片/文件的请求
2. Orchestrator 提取文件 → 存入 `{workspace}/media/inbound/{filename}`
3. 向 OpenClaw 发送引用消息：`[用户发送了文件: media/inbound/{filename}]`
4. OpenClaw 容器内自行识别文件类型、调用 image/read/exec 等工具处理

### 8.3 Fallback

如果 OpenClaw 内置工具无法处理（如 image 工具失败），Orchestrator 可调用外部视觉模型预处理，将描述文本转发给 OpenClaw。

---

## 9. 前端上下文管理

### 9.1 架构（混合方案）

- **权威数据源**：OpenClaw 容器内的会话记录（`agents/main/sessions/`）
- **后端 API**：`GET /api/v2/chat/history?limit=20&before={timestamp}` 从容器读取
- **iOS 本地缓存**：SwiftData 持久化，按用户隔离

### 9.2 交互流程

- **登录时**：先显示本地缓存（毫秒级），后台静默同步最新会话
- **发消息时**：同步写入本地缓存 + 发送后端
- **上滑加载**：分页从后端拉取更早消息
- **本地缓存上限**：200 条，更早的按需从后端拉取

---

## 10. OpenClaw 能力清单

### 10.1 内置工具

| 工具 | 功能 | 资源消耗 |
|------|------|---------|
| read / write / edit | 文件操作 | 极低 |
| exec / process | Shell 命令与后台进程 | 中（CPU） |
| image | 视觉模型分析图片 | Token（视觉模型） |
| web_search | 网页搜索（Brave） | API 调用 |
| web_fetch | 获取网页内容 | 低 |
| browser | Chromium 自动化 | 高（内存 300MB+） |
| cron | 定时任务 | 中（每次执行消耗 Token） |
| heartbeat | 周期性心跳 | 中 |
| memory_search / memory_get | 语义搜索记忆 | 低 |
| message | 跨平台消息（8+ 通道） | 低 |
| canvas | 设备 UI 展示 | 低 |
| nodes | 配对设备控制 | 低 |
| sessions_* | 多会话管理 | 低 |
| gateway | 网关配置管理 | 极低 |

### 10.2 扩展能力

- **技能系统**：SKILL.md 注入系统提示词，ClawHub 社区技能市场
- **记忆系统**：Markdown 文件 + BM25/向量混合检索
- **插件系统**：TypeScript 模块（工具、渠道、认证等）

---

## 11. 订阅分级模型

### Free —— 基础助手

| 类别 | 能力 | 限制 |
|------|------|------|
| 对话 | 文本对话 | 50 条/天 |
| 模型 | MiMo V2 Flash / GLM 4.6V Flash（免费模型） | max_tokens: 4096 |
| 多模态 | 图片识别 | 10 张/天 |
| 文件 | read / write / edit | workspace 限 100MB |
| Shell | exec（受限） | 禁止网络、限制进程数 |
| 网页 | 搜索 + 读取 | 各 20 次/天 |
| 记忆 | 完整（本地嵌入） | 记忆文件限 10MB |
| 技能 | 内置 + 最多 3 个自定义 | 不能安装社区技能 |
| 自动化 | 无 | cron/heartbeat 禁用 |
| 浏览器 | 无 | 禁用 |
| 消息通道 | 无 | 禁用 |
| 容器 | CPU: 0.5, 内存: 512MB | — |
| 备份 | 每 24 小时 | 保留 3 个 snapshot |

### Pro —— 全能助手

| 类别 | 能力 | 限制 |
|------|------|------|
| 对话 | 无限 | — |
| 模型 | DeepSeek Chat + 免费模型 | max_tokens: 8192 |
| 多模态 | 图片识别 | 无限 |
| 文件 | 完整 | workspace 限 500MB |
| Shell | 完整 | 允许网络 |
| 网页 | 搜索 + 读取 | 各 100 次/天 |
| 记忆 | 完整 + Gemini 嵌入 | 记忆文件限 50MB |
| 技能 | 全部 + 社区技能 | 无限 |
| 自动化 | cron + heartbeat | 最多 5 个定时任务 |
| 浏览器 | 基础 | 单标签页 |
| 消息通道 | Telegram / Discord | 2 个通道（自带 token） |
| 容器 | CPU: 0.75, 内存: 1.5GB | — |
| 备份 | 每 5 分钟 | 保留 30 个 snapshot |

### Premium —— 数字灵魂

| 类别 | 能力 | 限制 |
|------|------|------|
| 对话 | 无限 | — |
| 模型 | GLM-4.7 / Kimi K2 / DeepSeek Reasoner 等旗舰 | max_tokens: 16384 |
| 多模态 | 图片 + 音频 + 视频 | — |
| 文件 | 完整 | workspace 限 2GB |
| Shell | 完整 | — |
| 网页 | 搜索 + 读取 + 反爬虫 | 无限 |
| 记忆 | 完整 + 高级嵌入 | 无限制 |
| 技能 | 全部 | — |
| 自动化 | cron + heartbeat | 无限 |
| 浏览器 | 完整自动化 | 多标签页 |
| 消息通道 | 全部 8+ 通道 | 无限 |
| 容器 | CPU: 1.0, 内存: 2GB | — |
| 备份 | 每 1 分钟 | 无限 snapshot |

---

## 12. 安全边界

容器必须：
- 非 privileged
- 无宿主机敏感目录挂载
- CPU / 内存 / 磁盘限制（按 tier）
- 可限制出网（Free 禁止 / Pro 允许 / Premium 完全开放）

Secrets：
- 每 Runtime 一个 DEK（数据加密密钥）
- Envelope encryption
- 备份文件加密

---

## 13. 升级策略

- 不使用 `latest` tag
- 明确 `desired_version`
- 蓝绿升级
- 自动回滚
- 升级前强制 Checkpoint

---

## 14. 与 Manus 沙盒的差异

| 维度 | Manus | ClawBowl |
|------|-------|----------|
| 沙盒生命周期 | 短任务 | 常驻 |
| 状态 | 临时 | 持久 |
| 版本管理 | 无 | Snapshot |
| 用户身份 | 任务级 | Runtime 级 |
| 升级机制 | 无需 | 蓝绿部署 |
| 记忆 | 无 | 长期记忆 |
| 技能 | 预设 | 可自定义 + 社区 |

**ClawBowl 的本质**：把"任务沙盒"升级为"可版本化的个人 Agent 操作系统实例"。

---

## 15. 技术栈

| 层 | 技术 |
|----|------|
| iOS 客户端 | SwiftUI + SwiftData + PhotosUI |
| 后端控制面 | Python FastAPI + SQLAlchemy + Docker SDK |
| 执行面 | OpenClaw Gateway (Node.js) in Docker |
| 反向代理 | Nginx + Let's Encrypt |
| LLM 提供商 | ZenMux（聚合国内免费/低成本/旗舰模型） |
| 数据库 | SQLite（控制面元数据） |
| 认证 | JWT + Keychain（iOS） |

---

## 16. 当前阶段实施优先级

**立即做**：
1. 修复容器目录结构（对齐 `/root/.openclaw/`）
2. 多模态文件 inbox 机制（替代视觉模型预处理）
3. 前端上下文管理（SwiftData 缓存 + 后端历史 API + 分页加载）
4. Runtime 创建 + Snapshot#1
5. 周期 Checkpoint

**1.0 后做**：
1. 崩溃恢复
2. 蓝绿升级
3. 手动 reset
4. 订阅分级实施（Pro/Premium 模板）

**不要一开始做**：
- 分布式架构
- MicroVM
- 多 Agent 单实例迁移
- 实时双向同步
- Envelope encryption

---

## 17. 架构核心总结

ClawBowl 的核心不是"跑 OpenClaw"。

而是：**为每个用户维护一个可版本化、可恢复、可升级、可重置的"数字灵魂实例"。**

控制面管理生命周期。
执行面提供自由。
版本库保证安全与可控。
