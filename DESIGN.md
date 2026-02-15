# ClawBowl 系统设计文档（V5）

> 最后更新：2026-02-15

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

## 6. 数字灵魂备份系统

### 6.1 三层备份架构

```
┌─ 第一层：实时镜像（bind mount）─────────────────────────────┐
│  宿主机直接持有所有文件，容器崩溃不丢数据                    │
│  /var/lib/clawbowl/runtimes/{rid}/soul/                      │
│  ✅ Phase 0 已实现（当前架构天然具备）                        │
└──────────────────────────────────────────────────────────────┘
         ↓ 定期快照
┌─ 第二层：本地 Snapshot（tar.zst + JSON 摘要）───────────────┐
│  files.tar.zst    ← 原始文件完整备份（用于恢复）             │
│  soul_summary.json ← 核心字段结构化提取（用于查询/迁移）     │
│  manifest.json    ← 版本号、时间戳、SHA-256                  │
│  ⭐ Phase 1 实现基础版，Phase 3 加入 JSON 结构化              │
└──────────────────────────────────────────────────────────────┘
         ↓ 远期加密上传
┌─ 第三层：异地备份（OSS/S3）─────────────────────────────────┐
│  加密后上传云存储，防宿主机单点故障                           │
│  📋 Phase 4 实现                                             │
└──────────────────────────────────────────────────────────────┘
```

### 6.2 Snapshot 定义

每个 Snapshot 包含：

```
/var/lib/clawbowl/runtimes/{rid}/snapshots/{snap_id}/
  files.tar.zst          # 灵魂目录完整压缩包
  manifest.json          # 版本清单（见下）
  soul_summary.json      # 结构化摘要（Phase 3 加入）
```

**manifest.json：**

```json
{
  "rid": "uuid",
  "snap_id": "000012",
  "created_at": "2026-02-14T12:00:00Z",
  "source": "periodic|upgrade|crash|manual|pre_cron",
  "tier": "free",
  "openclaw_version": "2026.2.12",
  "files_hash": "sha256:...",
  "files_size_bytes": 5242880,
  "prev_snap_id": "000011"
}
```

**soul_summary.json（Phase 3 加入）：**

```json
{
  "version": "1.0",
  "rid": "f8a44871-...",
  "extracted_at": "2026-02-15T20:00:00Z",
  "soul": {
    "identity": "（IDENTITY.md 全文）",
    "personality": "（SOUL.md 全文）",
    "user_profile": "（USER.md 全文）",
    "memory_summary": "（MEMORY.md 全文）",
    "agent_rules": "（AGENTS.md 全文）",
    "tools": "（TOOLS.md 全文）"
  },
  "daily_memories": [
    { "date": "2026-02-14", "content": "..." },
    { "date": "2026-02-15", "content": "..." }
  ],
  "config": { "/* openclaw.json 内容 */" : "" },
  "stats": {
    "total_messages": 1234,
    "memory_files_count": 15,
    "workspace_size_bytes": 52428800
  }
}
```

**为什么同时保留 tar.zst 和 JSON？**

| 需求 | tar.zst | soul_summary.json |
|---|---|---|
| 灾难恢复 | ✅ 原样解压即可 | ❌ 需要 JSON→MD 反序列化 |
| 结构化查询 | ❌ 需要解压+读文件 | ✅ 直接解析 JSON |
| 跨版本迁移 | ❌ 依赖 OpenClaw 目录结构 | ✅ 通用格式，可注入任何系统 |
| 部分恢复 | ❌ 全量恢复 | ✅ 可只恢复记忆/人格 |
| 备份速度 | ✅ 极快（一个 tar 命令） | ⚠️ 需要解析 MD 文件 |

### 6.3 定期备份策略

| 级别 | 频率 | 保留数量 | 说明 |
|------|------|---------|------|
| Free | 每 24 小时 | 3 个 | 基本保护 |
| Pro | 每 5 分钟 | 30 个 | 约 2.5 小时回滚窗口 |
| Premium | 每 1 分钟 | 无限 | 精细粒度回滚 |

**备份流程**（无需进入容器，直接操作宿主机挂载目录）：

1. 从 `/var/lib/clawbowl/runtimes/{rid}/soul/` 打包 → `files.tar.zst`
2. 计算 SHA-256 → 写入 `manifest.json`
3. （Phase 3+）解析 MD 文件 → 生成 `soul_summary.json`
4. 更新 `runtime.json` 中的最新快照指针
5. 清理超出保留数量的旧快照

**特殊触发时机**：
- 容器升级前（`source: "upgrade"`）
- 启用 cron/heartbeat 前（`source: "pre_cron"`）
- 用户手动触发（`source: "manual"`）
- 容器崩溃检测到后立即备份当前状态（`source: "crash"`）

---

## 7. 生命周期管理

### 7.1 新用户注册

1. 选择模板（free/pro）
2. 生成 runtime_id
3. 创建 Snapshot#000001（从模板）
4. 启动容器（带资源限制）
5. 注入 Snapshot
6. 运行健康检查

### 7.2 容器资源管理

> **设计原则**：CPU/内存/存储成本极低，不作为订阅分级维度。所有用户统一给充裕资源，系统自动管理，用户完全无感。订阅差异体现在 LLM 模型等级和 token 额度上（详见第 12 章）。

**统一资源标准（所有订阅级别）：**

| 资源 | 默认值 | 上限 | 说明 |
|---|---|---|---|
| CPU | 1 核 | 系统自动调整 | 空闲时可被其他容器共享 |
| 内存 | 2 GB | 系统自动调整 | 浏览器任务可临时提升 |
| 存储 | 2 GB | 通知清理 | bind mount，不受容器限制 |

**系统自动伸缩（用户无感）：**

| 场景 | 系统行为 |
|---|---|
| 容器空闲 | 降低 CPU 权重，资源让给活跃容器 |
| 复杂任务执行中（浏览器/编程） | 临时提升 CPU/内存，完成后回收 |
| 内存接近上限 | 自动扩容（`docker update`），无需重启 |
| 存储接近上限 | 通知用户 + Agent 自动清理临时文件 |

**技术实现**：
- CPU/内存：`docker update --cpus=N --memory=Xg`，即时生效，无需重建容器
- 存储：bind mount 天然不受容器限制，控制面定期 `du -s` 监控
- 多用户场景（Phase 4+）：CPU 使用 `--cpu-shares` 做权重分配，保证公平性

### 7.3 容器崩溃恢复

1. 停止崩溃容器
2. 立即对当前 soul 目录做崩溃快照（`source: "crash"`）
3. 选择最近**成功**的 Snapshot 恢复
4. 启动新容器
5. 注入 Snapshot
6. 健康检查
7. 失败则回退到上一个 Snapshot

### 7.4 容器升级（蓝绿部署）

1. 强制 Checkpoint（`source: "upgrade"`）
2. 拉取新镜像
3. 使用最近 Snapshot 启动新容器（green）
4. 健康检查通过 → 切流量
5. 停止旧容器
6. 失败则回滚到 Checkpoint

### 7.5 容器重置

**Soft Reset**：
- 恢复到 Snapshot#000001
- 不删除历史快照

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

## 9. 前端设计哲学

### 9.1 极简原则

**核心理念：上下文管理是 AI 的工作，不是用户的工作。**

ClawBowl 的前端永远只有一个对话窗口，不展示多个对话线程。这与 ChatGPT、Claude 等产品的设计理念根本不同：

| 传统 AI 产品 | ClawBowl |
|---|---|
| 多个对话线程，用户手动切换 | **单一对话流**，AI 自动管理上下文 |
| 用户需要决定"这个问题属于哪个对话" | **用户只需说话**，AI 自动关联历史 |
| 上下文切换是用户操作 | 上下文切换由 memory_search 自动完成 |
| 对话历史 = 用户整理的线程列表 | 对话历史 = **AI 的记忆**（分类存储，按需调取） |

**UI 布局**：
```
┌─────────────────────────┐
│  [状态栏]               │
│                         │
│  💬 消息流（单线程）      │
│                         │
│  📎  🎤  [输入框]  ➤    │
└─────────────────────────┘
```

仅 4 个交互元素：附件按钮、语音按钮、文本输入框、发送按钮。

### 9.2 语音输入

**方案：iOS 本地转写（Speech 框架）**

```
用户按住🎤 → iOS Speech 实时转写 → 文字填入输入框 → 用户确认发送
```

- 使用 iOS 内置 Speech 框架，中文识别准确率高
- 零上传成本，毫秒级转写，支持离线
- 对后端完全透明——就是一条普通文本消息
- 未来可扩展：语音情感分析、声纹识别（Phase 5 挂载音频处理模块）

### 9.3 iOS 原生功能集成（规划中）

Agent 回复中可夹带**结构化指令**，iOS App 解析后执行本地操作：

```
用户："帮我在日历上添加明天下午3点的会议"
  → Agent 理解意图
  → 返回：{ "action": "calendar_add", "title": "会议", "date": "..." }
  → iOS 调用 EventKit → 完成
  → App 回复 Agent："已添加到日历"
```

| 功能 | iOS 框架 | 可行性 | 阶段 |
|---|---|---|---|
| 日历（增删改查） | EventKit | ✅ 完全可以 | Phase 3 |
| 提醒事项/备忘 | EventKit (Reminders) | ✅ 完全可以 | Phase 3 |
| 定时提醒（代替闹钟） | UNUserNotificationCenter | ✅ 本地推送 | Phase 3 |
| 打开其他 App | URL Scheme | ✅ 有限支持 | Phase 3 |
| Siri 快捷指令 | App Intents (iOS 16+) | ✅ 可以 | Phase 4 |
| 通讯录 | Contacts 框架 | ✅ 需授权 | Phase 4 |
| 位置服务 | CoreLocation | ✅ 需授权 | Phase 4 |
| 健康数据 | HealthKit | ✅ 需授权 | Phase 5 |

注：iOS 没有公开闹钟 API，用本地推送通知替代，效果相同。

---

## 10. 前端上下文管理

### 10.1 架构（混合方案）

- **权威数据源**：OpenClaw 容器内的会话记录（`agents/main/sessions/`）
- **后端 API**：`GET /api/v2/chat/history?limit=20&before={timestamp}` 从容器读取
- **iOS 本地缓存**：SwiftData 持久化，按用户隔离

### 10.2 交互流程

- **登录时**：先显示本地缓存（毫秒级），后台静默同步最新会话
- **发消息时**：同步写入本地缓存 + 发送后端
- **上滑加载**：分页从后端拉取更早消息
- **本地缓存上限**：200 条，更早的按需从后端拉取

---

## 11. OpenClaw 能力清单

### 11.1 内置工具

| 工具 | 功能 | 资源消耗 |
|------|------|---------|
| read / write / edit | 文件操作 | 极低 |
| exec / process | Shell 命令与后台进程 | 中（CPU） |
| image | 视觉模型分析图片 | Token（视觉模型） |
| web_search | 网页搜索（Tavily，原 Brave 国内不可用） | API 调用 |
| web_fetch | 获取网页内容 | 低 |
| browser | Chromium 自动化 | 高（内存 300MB+） |
| cron | 定时任务 | 中（每次执行消耗 Token） |
| heartbeat | 周期性心跳 | 中 |
| memory_search / memory_get | 语义搜索记忆 | 低 |
| message | 跨平台消息（OpenClaw 内置，ClawBowl 不使用） | — |
| canvas | 设备 UI 展示 | 低 |
| nodes | 配对设备控制 | 低 |
| sessions_* | 多会话管理 | 低 |
| gateway | 网关配置管理 | 极低 |

### 11.2 扩展能力

- **技能系统**：SKILL.md 注入系统提示词，ClawHub 社区技能市场
- **记忆系统**：Markdown 文件 + BM25/向量混合检索
- **插件系统**：TypeScript 模块（工具、渠道、认证等）

---

## 12. 订阅分级模型

### 12.1 成本结构分析

> **核心洞察**：当前 CPU/内存/存储成本极低且持续下降，真正的成本驱动因素是高级 LLM 的 token 消耗。因此：
> - **容器资源**：统一给充裕的默认值，系统自动管理，用户完全无感
> - **订阅差异**：主要体现在 LLM 模型等级和 token 额度上
> - **用户感知**：只关心"AI 能帮我做什么"，不关心"我的容器有多大"

**成本构成估算（单用户/月）：**

| 成本项 | 月费用 | 占比 | 说明 |
|---|---|---|---|
| 容器（CPU + 内存） | ≈ ¥5-15 | 5%-10% | 极低，自动伸缩 |
| 存储 | ≈ ¥1-3 | < 2% | 可忽略 |
| **LLM token（免费模型）** | ¥0 | — | GLM Flash / MiMo 等 |
| **LLM token（中端模型）** | ≈ ¥10-50 | **50%-70%** | DeepSeek V3.2 / GLM-5 |
| **LLM token（旗舰模型）** | ≈ ¥50-200+ | **70%-90%** | Kimi K2.5 / DeepSeek Reasoner |
| 搜索 API | ≈ ¥5-10 | 5% | Tavily / Kimi 搜索 |

### 12.2 订阅分级

**所有级别共享的基础能力**（容器资源不是差异化维度）：

| 类别 | 能力 | 说明 |
|---|---|---|
| 容器资源 | CPU 1 核 / 内存 2GB / 存储 2GB | 统一标准，系统按需自动伸缩 |
| 文件操作 | read / write / edit / exec | 全量开放 |
| 记忆系统 | MEMORY.md + 日记 + memory_search | 完整 |
| 消息通道 | 仅 App | 设计决策 |
| 备份 | 每日自动 Snapshot | 保留 7 个 |

#### Free —— 体验助手

用户零成本体验，系统仅使用免费模型。

| 类别 | 能力 | 限制 |
|------|------|------|
| **模型** | MiMo V2 Flash / GLM 4.6V Flash | 仅免费模型 |
| **日对话量** | 50 条/天 | — |
| **输出长度** | max_tokens: 4096 | — |
| 多模态 | 图片识别 | 10 张/天 |
| 网页搜索 | Tavily 基础 | 20 次/天 |
| 自动化 | 无 | cron/heartbeat 禁用 |
| 浏览器 | 无 | 禁用 |
| 技能 | 内置 + 3 个自定义 | 不能安装社区技能 |

#### Pro —— 全能助手

核心价值：解锁中端付费模型 + 自动化 + 浏览器。

| 类别 | 能力 | 限制 |
|------|------|------|
| **模型** | DeepSeek V3.2 / GLM-5 + 免费模型 | 中端模型 |
| **月 token 额度** | 500 万 token（约 ¥30 成本） | 超额降速到免费模型 |
| **输出长度** | max_tokens: 8192 | — |
| 多模态 | 图片识别 | 无限 |
| 网页搜索 | Tavily + Kimi 搜索增强 | 100 次/天 |
| 自动化 | cron + heartbeat | 最多 5 个定时任务 |
| 浏览器 | 基础自动化 | 单标签页 |
| 技能 | 全部 + 社区技能 | 无限 |
| 备份 | 每 5 分钟 | 保留 30 个 |

#### Premium —— 数字灵魂

核心价值：解锁旗舰模型 + 无限额度 + 完整自动化。

| 类别 | 能力 | 限制 |
|------|------|------|
| **模型** | Kimi K2.5 / DeepSeek Reasoner / GLM-5 全系列 | **旗舰模型** |
| **月 token 额度** | 无限 | — |
| **输出长度** | max_tokens: 16384 | — |
| 多模态 | 图片 + 音频 + 视频 | 无限 |
| 网页搜索 | 全部搜索引擎 + 反爬虫 | 无限 |
| 自动化 | cron + heartbeat | 无限 |
| 浏览器 | 完整自动化 | 多标签页 |
| 技能 | 全部 | — |
| 备份 | 每 1 分钟 | 无限 |

### 12.3 超额策略

用户不会遇到"突然不能用"的情况：

| 情况 | 处理方式 |
|---|---|
| Pro 用户 token 额度用完 | **自动降级到免费模型**继续使用，而非停止服务 |
| Free 用户达到日对话上限 | 提示"今日额度已用完，明日重置"或引导升级 |
| 存储接近上限 | 通知用户 + Agent 自动清理临时文件 |

---

## 13. 安全边界

容器必须：
- 非 privileged
- 无宿主机敏感目录挂载
- 统一资源上限（CPU 1 核 / 内存 2GB / 存储 2GB），防止单容器耗尽宿主机资源
- 可限制出网（Free 限制外网访问 / Pro+ 完全开放）

Secrets：
- 每 Runtime 一个 DEK（数据加密密钥）
- Envelope encryption
- 备份文件加密

---

## 14. 升级策略

- 不使用 `latest` tag
- 明确 `desired_version`
- 蓝绿升级
- 自动回滚
- 升级前强制 Checkpoint

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

## 16. 产品定位与竞品差异

### 16.1 产品定位

**ClawBowl = 个人 AI 助理操作系统**

不同于 Manus（一次性任务执行器）或 ChatGPT（无状态对话），ClawBowl 提供的是：
- 一个**持久化**的 AI 助理，越用越了解你
- 一个**固定沙盒**，工具和环境持续积累
- 一个**可版本化的数字灵魂**，可备份、可恢复、可升级

### 16.2 与竞品对比

| 维度 | ChatGPT/Kimi | Manus | OpenClaw（原生） | **ClawBowl** |
|---|---|---|---|---|
| 沙盒 | 无/临时 | 临时（任务级） | 固化（持久） | **固化（持久）** |
| 记忆 | 会话级/摘要式 | 任务级（无跨任务记忆） | 持久化（文件级） | **持久化 + 自动沉淀** |
| 工具执行 | Code Interpreter | 多线程沙盒 | 持久沙盒 | **持久沙盒（工具累积）** |
| 自动化 | 无 | 无 | cron + heartbeat | **cron + heartbeat + iOS 推送** |
| 浏览器 | 无 | 有 | 有（Chromium） | **有（Chromium，规划中）** |
| 个性化 | 低 | 无 | 高（SOUL/USER.md） | **高（SOUL/USER.md）** |
| 设备集成 | 无 | 无 | 无 | **日历/提醒/通知（规划中）** |
| 部署门槛 | 零 | 零 | **极高** | **零（App 即用）** |
| 数据主权 | 供应商持有 | 供应商持有 | 用户自有 | **用户自有** |
| LLM 选择 | 锁定 | 锁定 | 可选 | **可选（国内模型友好）** |
| 成本控制 | 订阅制固定 | 按任务收费 | 按 API 用量 | **多模型路由，弹性控制** |

### 16.2.1 竞品痛点深度分析

**Manus 痛点：**
- **无固化沙盒**：每次任务从零搭建环境（安装依赖、下载数据），重复消耗大量 token 和时间
- **无跨任务记忆**：上周做的事这周完全不记得，用户必须自己充当记忆体
- **纯被动执行**：无 cron 调度能力，不能定时自动执行任务
- **成本不透明**：复杂任务可能消耗大量资源，用户难以预判

**OpenClaw 痛点：**
- **部署门槛极高**：需要 Docker、域名、SSL、API Key 等知识，99% 的用户倒在部署阶段
- **依赖第三方聊天平台**：Telegram/Discord/WhatsApp 对国内用户不友好；企微/飞书需要复杂的应用创建和回调配置
- **平台体验不一致**：每个聊天平台的消息格式、附件限制、交互能力不同，体验参差不齐
- **无法感知用户设备**：通过聊天平台中转，无法访问手机日历、提醒等原生功能

**ClawBowl 的差异化定位：**
- 取 Manus 的"强执行力" + OpenClaw 的"固化沙盒与记忆" + 自研 App 的"零门槛体验"
- 核心价值：**为普通用户提供一个即开即用、越用越聪明的个人 AI 助理**

### 16.3 核心架构策略

**前端收敛（App 是唯一消息通道）**：不使用 OpenClaw 的 8+ 消息通道，统一通过自有 iOS App 对接用户。这是核心设计决策，不是临时妥协。
- 用户体验完全可控，不受第三方平台限制
- 国内聊天平台（微信/企微/飞书）消息 API 极其复杂且审核严格，普通用户无法配置
- 单一入口保证所有交互、记忆、上下文的完整性
- 未来扩展 Android/Web 客户端时，后端 API 不变，只是增加前端形态

**后端模块化（微内核架构）**：
```
iOS App ──── API Gateway ──┬── 消息转发模块（proxy.py）
                           ├── LLM 管理模块（模型切换、计费、限流）
                           ├── 记忆模块（OpenClaw 内置，可替换）
                           ├── 用户数据模块（认证、配额、偏好）
                           └── 沙盒管理模块（Docker 生命周期）
```

**OpenClaw 定位**：当前作为"能力底座"使用，所有接口抽象化，未来可替换为自建或其他框架。

---

## 17. 国内 LLM 生态与 ClawBowl 模型策略

> 更新时间：2026-02-15

### 17.1 全球前沿模型最新格局（截至 2026-02-15）

2026 年 2 月，国际和国内同时迎来模型密集发布期。国内模型与国际第一梯队的差距已从约 7 个月缩短至约 3 个月。

#### 国际前沿（2026 年 2 月发布）

| 模型 | 厂商 | 发布日期 | 上下文 | 核心突破 |
|---|---|---|---|---|
| **Claude Opus 4.6** | Anthropic | 2月5日 | 1M token | ARC-AGI-2 从 37.6%→68.8%（抽象推理最大单代跃升）；自适应思考（4 档推理深度）；Agent Teams 多实例协作；上下文压缩实现无限对话 |
| **GPT-5.3 Codex** | OpenAI | 2月5日 | 128K | Agent 编程专用模型；比 5.2 快 25%；首个获"高"级网络安全认证的模型 |
| **GPT-5.3 Codex Spark** | OpenAI | 2月13日 | 128K | 超低延迟（1000+ tok/s），Cerebras 晶圆级引擎驱动，实时编程交互 |
| **Gemini 3 Pro** | Google | 预览中 | 1M token | AIME 2025 满分（100%），GPQA 91.9%，多模态（文本/图片/音频/视频/PDF） |
| **Grok 4.1** | xAI | 2026年1月 | — | 视频生成/编辑，Batch API，企业级 |

#### 国内前沿（2026 年春节档）

| 模型 | 厂商 | 参数量 | 上下文 | 核心优势 | 开源 |
|---|---|---|---|---|---|
| **DeepSeek V4**（即将发布） | 深度求索 | MoE | 1M token | 编程能力目标超越 Claude，稀疏注意力+流形约束+印迹记忆技术 | ✅ MIT |
| **GLM-5** | 智谱 AI | 744B（40B 激活） | 200K token | Agent 能力开源最高（指数 63），幻觉率 90%→34%，纯国产昇腾芯片训练 | ✅ MIT |
| **Kimi K2.5** | 月之暗面 | 1T | 256K | 100 个子 Agent 并行协调，长程任务 4.5x 加速，AIME 96% | 部分开源 |
| **Qwen3-Coder** | 阿里 | 480B（35B 激活） | 256K-1M | Agent 编程对标 Claude Sonnet 4，358 种语言，RL 训练多轮交互 | ✅ |
| **Qwen3-Max-Thinking** | 阿里 | — | — | 自主工具选择（搜索/记忆/代码），经验累积推理 | — |
| **MiniMax 2.5** | MiniMax | 10B 激活 | — | 100 TPS 高吞吐，轻量开发者友好 | — |
| **豆包 2.0** | 字节跳动 | — | — | 日活最高，语音交互最佳，多模态（图/视频生成） | — |

### 17.2 关键能力基准对比

#### 编程能力

| 模型 | SWE-bench Verified | Terminal-Bench 2.0 | 说明 |
|---|---|---|---|
| **Claude Opus 4.6** | 80.8% | 69.9% | 当前综合最强 |
| **GPT-5.3 Codex** | — | **77.3%** | Terminal-Bench 最高 |
| **GLM-5** | **77.8%** | 56.2% | 开源编程最强 |
| Gemini 3 Pro | 76.2% | — | |
| **Kimi K2.5** | 76.8% | — | |
| DeepSeek V3.2 | ~74% | — | V4 目标 >80% |
| **Qwen3-Coder** | 对标 Claude Sonnet 4 | — | 仓库级代码理解 |

#### 推理能力

| 模型 | ARC-AGI-2 | AIME 2025 | GPQA Diamond | HLE（带工具） |
|---|---|---|---|---|
| **Claude Opus 4.6** | **68.8%** | — | — | 53.1% |
| **Gemini 3 Pro** | 31.1% | **100%** | **91.9%** | 45.8% |
| **Kimi K2.5** | — | 96% | — | — |
| **GLM-5** | — | — | — | 50.4% |

#### Agent / 工具使用能力

| 模型 | 定位 | Agent 能力亮点 |
|---|---|---|
| **Claude Opus 4.6** | 标杆 | Agent Teams 多实例协作，OSWorld 72.7%，BrowseComp 84.0% |
| **GPT-5.3 Codex** | 编程 Agent | OSWorld 64.7%（+26.5pp），长程研究+工具链 |
| **GLM-5** | 开源最强 | Agent Index 63（开源最高），深度优先策略 |
| **Kimi K2.5** | 并行编排 | 100 子 Agent 并行，1500 次工具调用 |
| **Qwen3-Coder** | 编程 Agent | RL 训练 Agent 交互，SWE-Bench 实战优化 |

#### 成本对比（每百万 token）

| 模型 | 输入 | 输出 | 说明 |
|---|---|---|---|
| **Claude Opus 4.6** | $5 | $25 | 较 4.5 大幅降价（原 $15/$75） |
| **GPT-5.3 Codex** | ~$10 | ~$30 | |
| Gemini 3 Pro | ~$3.5 | ~$10.5 | 1M 上下文价格优势 |
| **GLM-5** | **$0.11** | **$0.11** | 极低，MIT 开源 |
| **DeepSeek V3.2** | **$0.28** | **$0.42** | 低成本领跑 |
| **MiniMax 2.5** | ~$0.15 | ~$0.15 | 轻量高吞吐 |
| **Kimi K2.5** | ~$0.50 | ~$1.00 | 推理速度快(39 tok/s) |

> **成本差距惊人**：国内模型成本仅为国际模型的 1/50 ~ 1/200，且均为开源（MIT）。这意味着 ClawBowl 可以在极低成本下提供接近国际顶级的 Agent 能力。

### 17.3 ClawBowl 的 LLM 策略

#### 当前配置

| 用途 | 模型 | 说明 |
|---|---|---|
| 主力对话 | DeepSeek V3.2 via ZenMux | 低成本、推理能力强 |
| 图片分析 | GLM 4.6V Flash | 免费多模态 |
| 推理任务 | MiMo V2 Flash | 免费、推理优化 |

#### 近期升级计划

| 优先级 | 动作 | 目标 |
|---|---|---|
| ⭐⭐⭐ | DeepSeek V4 上线后切换主力模型 | 编程+Agent 能力大幅提升 |
| ⭐⭐⭐ | GLM-5 作为备选主力模型 | Agent 能力强，成本极低（$0.11/M） |
| ⭐⭐ | Qwen3-Coder 用于复杂编程任务 | 仓库级代码理解 |
| ⭐⭐ | ZenMux 智能路由 | 简单对话→免费模型，复杂任务→旗舰模型 |
| ⭐ | Kimi K2.5 用于超长文档处理 | 20 万字上下文 |

#### 模型策略原则

1. **不锁定单一模型**：通过 ZenMux 聚合层接入多个模型，按任务类型智能路由
2. **优先国内模型**：DeepSeek、GLM、Qwen 均有 API 在国内可直接访问，无需翻墙
3. **成本分级**：
   - 日常对话 → 免费/极低成本模型（GLM-5、MiMo）
   - 复杂推理 → 中等成本模型（DeepSeek V4）
   - 关键任务 → 旗舰模型（按需切换）
4. **开源优先**：GLM-5 和 DeepSeek 均为 MIT 协议，未来可本地部署降低成本
5. **关注 Agent 能力**：ClawBowl 的核心体验依赖 LLM 的工具调用准确率和多步推理能力，优先选择 Agent 基准分高的模型

#### 风险与对冲

| 风险 | 影响 | 对冲策略 |
|---|---|---|
| 国内模型 Agent 能力不足 | 工具调用失败率高 | ZenMux 多模型路由，关键任务可切换到强模型 |
| API 服务不稳定 | 用户体验中断 | 多供应商备份（DeepSeek + GLM + Qwen） |
| 模型升级导致行为变化 | Agent 提示词失效 | SOUL.md / AGENTS.md 版本化管理 |
| 国际模型封锁加剧 | 无法使用 Claude/GPT | 国内模型已接近可用水平，且持续追赶 |

---

## 18. OpenClaw 功能激活路径

### Phase 0 — 核心基础 ✅（已完成）

| 能力 | 说明 | 状态 |
|---|---|---|
| 文本对话 | DeepSeek V3.2 via ZenMux | ✅ |
| 文件处理 | read/write/edit + exec | ✅ |
| 图片分析 | GLM 4.6V Flash 视觉模型 | ✅ |
| 通用附件 | 任意文件 → workspace → agent 处理 | ✅ |
| 网页搜索 | Tavily Search API（Brave 国内不可用，已替换） | ✅ |
| 网页读取 | web_fetch + Readability | ✅ |
| 持久会话 | user + session-key → 跨请求复用 session | ✅ |
| 记忆系统 | MEMORY.md + memory/ 日记 + memory_search | ✅ |
| 工具记忆 | TOOLS.md 自动更新 | ✅ |
| 推理展示 | thinking 浅色字体 + 最终 content 分离 | ✅ |

### Phase 1 — 自主能力 + 基础备份（下一步）

目标：agent 从"被动回答"进化为"主动行动"，同时建立数据安全网。

| 能力 | 实现方式 | 前端改动 | 后端改动 | 优先级 |
|---|---|---|---|---|
| **基础 Snapshot** | tar.zst + manifest.json（详见第 6 章） | 无 | 定时任务 + 控制面 API | ⭐⭐⭐ |
| **Cron 定时任务** | 启用 cron 工具 + HEARTBEAT.md | 添加"定时任务"管理 UI | openclaw.json 启用 cron | ⭐⭐⭐ |
| **Heartbeat 心跳** | 配置 heartbeat 周期 | 无（后台自动） | HEARTBEAT.md 配置检查项 | ⭐⭐⭐ |
| **子 Agent 派生** | sessions_spawn（ping-pong） | 无（透明执行） | 启用 session tools | ⭐⭐ |
| **ClawHub 技能** | 安装社区技能到 workspace/skills/ | 添加"技能市场"入口 | 无（agent 自行安装） | ⭐⭐ |

> **为什么基础备份必须在 Phase 1？** 启用 cron/heartbeat 后 Agent 开始自主行动，如果出错必须能回滚。没有备份就启用自动化 = 裸奔。

**预期效果**：
- 用户说"每天早上 9 点帮我查天气" → agent 自动创建 cron
- Agent 定期自主检查记忆、整理笔记
- 复杂任务自动拆解为子任务
- 任何操作出错 → 可从最近快照恢复

### Phase 2 — 浏览器自动化

目标：agent 能代替用户操作网页。

| 能力 | 实现方式 | 前端改动 | 后端改动 | 优先级 |
|---|---|---|---|---|
| **基础浏览器** | Chromium + Playwright in Docker | 显示截图/结果 | Docker 镜像安装 Chromium | ⭐⭐⭐ |
| **网页截图** | browser screenshot → 返回图片 | 图片消息展示 | 无 | ⭐⭐ |
| **表单填写** | browser act (fill/click/type) | 无 | 无 | ⭐⭐ |
| **多标签页** | browser tabs management | 无 | Premium 配置 | ⭐ |

**预期效果**：
- "帮我在京东上搜一下 iPhone 16 的价格" → agent 打开浏览器自动操作
- "截图保存这个网页" → agent 浏览并截图返回

**Docker 镜像改造**：
```dockerfile
RUN apt-get install -y chromium
RUN npx playwright install --with-deps chromium
```

### Phase 3 — 智能化升级

目标：更强的模型、更丰富的数据源、更智能的工作流。

> **国内网络适配**：Phase 3 的所有功能均基于国内可达的服务和开源方案，不依赖被封锁的境外 API。

| 能力 | 实现方式 | 国内可行性 | 说明 | 优先级 |
|---|---|---|---|---|
| **多模型智能路由** | ZenMux 管理模块（无前端选择器） | ✅ 国内模型 | 后端按任务复杂度自动路由：简单→免费模型，复杂→旗舰 | ⭐⭐⭐ |
| **AI 增强搜索** | Kimi/GLM 搜索增强 API + Tavily 备用 | ✅ 国内直连 | 替代 Perplexity（国内被封锁）；国内 LLM 自带搜索覆盖国内站点更全 | ⭐⭐ |
| **反爬虫抓取** | 复用 Phase 2 Playwright + Crawl4AI（开源自托管） | ✅ 本地部署 | 替代 Firecrawl（抓取国内站点效果差）；Playwright 已在 Phase 2 部署 | ⭐⭐ |
| **语义嵌入** | SiliconFlow/bge-large-zh 或 Tencent Youtu | ✅ 国内直连 | 替代 OpenAI/Gemini（国内不可用）；国内模型中文 CMTEB 排名更高 | ⭐⭐ |
| **Lobster 工作流** | 安装 Lobster CLI（容器内本地运行） | ✅ 无需外网 | 确定性流水线 + 审批门控，不依赖外部网络 | ⭐ |
| **灵魂 JSON 结构化** | 备份时生成 soul_summary.json（详见第 6 章） | ✅ 本地 | 支持记忆查询、部分恢复、跨系统迁移 | ⭐⭐ |

**国内替代方案说明：**

| 原方案（国内不可用） | 替代方案 | 优势 |
|---|---|---|
| Perplexity API | Kimi 搜索增强 / GLM Web Search / Tavily | 国内站点覆盖更全，中文结果更好 |
| Firecrawl | Playwright 自建 + Crawl4AI | 免费，对国内反爬虫站点兼容性更好 |
| OpenAI/Gemini Embeddings | bge-large-zh (SiliconFlow) / Tencent Youtu | CMTEB 中文排名 #1-#2，接口兼容 OpenAI 格式 |

### Phase 4 — 平台化

目标：从单用户工具升级为可运营的平台。

| 能力 | 说明 | 优先级 |
|---|---|---|
| **订阅分级实施** | Free/Pro/Premium 模板 + 配额控制 | ⭐⭐⭐ |
| **多用户资源调度** | `--cpu-shares` 权重分配 + 自动伸缩（详见第 7 章） | ⭐⭐ |
| **异地备份** | 快照加密后上传 OSS/S3，防宿主机单点故障 | ⭐⭐⭐ |
| **Android 客户端** | Kotlin/Compose，复用后端 API | ⭐⭐ |
| **Web 客户端** | React/Vue，轻量版入口 | ⭐⭐ |
| **多用户容器编排** | K8s / Docker Swarm | ⭐ |
| **Canvas WebView** | iOS App 内嵌 WebView 替代 node Canvas | ⭐ |

> 注：基础 Snapshot 已在 Phase 1 实现，此处的重点是**异地冗余**和**多用户场景下的自动扩缩容**。

### Phase 5 — OpenClaw 替换（远期）

目标：逐步用自建模块替换 OpenClaw，降低外部依赖。

| 替换顺序 | 模块 | 自建难度 | 说明 |
|---|---|---|---|
| 1 | System Prompt 组装 | 低（100 行） | 自己注入 workspace 文件到 context |
| 2 | 工具系统 | 低（500 行） | subprocess + 文件 I/O + API 调用 |
| 3 | Agent Loop | 中（800 行） | LLM → tool_calls → 执行 → 循环 |
| 4 | 会话管理 | 中（500 行） | transcript 存储 + 压缩 + 记忆冲刷 |
| 5 | 浏览器自动化 | 高（Playwright 集成） | 直接用 Playwright Python |
| 6 | 记忆语义搜索 | 中（embedding + SQLite） | 本地嵌入 + 向量检索 |

**替换原则**：先稳定产品，再逐步替换。每替换一个模块，确保前端和用户无感。

---

## 19. 当前阶段实施优先级

**已完成** ✅：
1. ~~容器目录结构~~
2. ~~多模态文件 inbox 机制~~
3. ~~持久会话 + 记忆系统~~
4. ~~推理过程/最终结果分离~~
5. ~~TOOLS.md 自动维护~~

**立即做**（Phase 1）：
1. **基础 Snapshot 备份**（tar.zst + manifest，为后续自动化兜底）
2. 启用 Cron + Heartbeat
3. 配置 HEARTBEAT.md 自动检查项
4. 启用 sessions_spawn（子任务）
5. 前端"定时任务"管理 UI

**1.0 后做**（Phase 2-3）：
1. Docker 镜像安装 Chromium + Playwright
2. 浏览器自动化启用
3. 多模型智能路由（ZenMux 按任务复杂度自动切换）
4. 语义嵌入升级（SiliconFlow/bge 或 Tencent Youtu）
5. AI 增强搜索（Kimi/GLM 搜索 + Tavily）
6. 灵魂 JSON 结构化提取（soul_summary.json）

**长期规划**（Phase 4-5）：
1. 订阅分级 + token 计量计费
2. 异地加密备份（OSS/S3）
3. 多端客户端（Android/Web）
4. OpenClaw 模块逐步替换

**不要一开始做**：
- 分布式架构
- MicroVM
- 多 Agent 单实例迁移
- 实时双向同步
- Envelope encryption

---

## 20. 架构核心总结

ClawBowl 的核心不是"跑 OpenClaw"。

而是：**为每个用户维护一个可版本化、可恢复、可升级、可重置的"数字灵魂实例"。**

控制面管理生命周期。
执行面提供自由。
版本库保证安全与可控。
OpenClaw 是当前的能力底座，但不是不可替代的依赖。

**核心资产（不可替代）**：
- iOS App（用户交互层）
- 后端 API Gateway（控制层）
- 用户体系 + 数据库
- Docker 编排逻辑
- 产品设计思路（固定沙盒 + 持久记忆 + 成长型助手）

**可替换模块（供应商）**：
- OpenClaw（沙盒 + Agent Loop）→ 可自建
- DeepSeek / GLM / Qwen / ZenMux（LLM 提供商）→ 多模型智能路由
- Tavily / Kimi 搜索 / GLM Web Search（搜索 API）→ 多供应商互备
- SiliconFlow/bge / Tencent Youtu（语义嵌入）→ 国内可达，兼容 OpenAI 格式
- Playwright + Crawl4AI（反爬虫抓取）→ 开源自托管
