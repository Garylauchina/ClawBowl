# ClawBowl 系统设计文档（V5）

> 最后更新：2026-02-18

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

> **设计原则**：容器规模是免费用户的成本控制手段（小容器 = 低成本），而非用户体验的差异点。用户感知到的差异是"灵魂容量"（记忆空间大小），而非技术参数。详见第 12 章。

**容器资源按订阅级别：**

| 资源 | Free | Pro | Premium |
|---|---|---|---|
| CPU | 0.5 核 | 1 核 | 1 核（自动伸缩） |
| 内存 | 512 MB | 1.5 GB | 2 GB |
| workspace 存储 | 200 MB | 500 MB | 2 GB |
| 记忆文件上限 | 10 MB | 50 MB | 无限 |

**系统自动伸缩（用户无感）：**

| 场景 | 系统行为 |
|---|---|
| 容器空闲 | 降低 CPU 权重，资源让给活跃容器 |
| 复杂任务执行中（浏览器/编程） | 临时提升 CPU/内存，完成后回收 |
| 记忆/存储接近上限 | **Agent 自动优化**：压缩归档旧记忆、清理临时文件（非限制用户） |
| 用户升级订阅 | `docker update` 即时扩容，无需重建容器 |

**技术实现**：
- CPU/内存热扩容：`docker update --cpus=N --memory=Xg`，即时生效
- 存储：bind mount 天然不受容器限制，控制面定期 `du -s` 监控
- 多用户场景（Phase 4+）：`--cpu-shares` 权重分配，保证公平性

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

### 8.4 文件下载（Agent 生成文件 → 用户手机）

Agent 在容器内生成的文件（PDF、PPT、文档、图片等）需要交付给用户。由于容器 workspace 通过 bind mount 已在宿主机上，只需补全"后端下载 API + 前端文件卡片"两个环节。

**完整链路：**

```
Agent 生成文件（workspace/report.pdf）
      ↓  bind mount，文件已在宿主机
后端检测 workspace 新增文件 → 注入 file 事件到 SSE 流
      ↓
iOS 解析 file 事件 → 渲染文件卡片
      ↓
用户点击 → iOS 调用下载 API → 预览/分享
```

**后端实现：**

1. **下载 API**：`GET /api/v2/files/download?path={relative_path}`
   - 将 path 映射到 `/var/lib/clawbowl/runtimes/{rid}/workspace/{path}`
   - JWT 鉴权 + 路径校验（防目录穿越）
   - 返回文件流 + Content-Type + Content-Disposition

2. **文件检测**（两种方式互补）：
   - **workspace diff**：对话结束后对比 workspace 目录快照，找到新增文件（100% 准确）
   - **响应文本解析**：正则匹配 `.pdf/.pptx/.docx/.xlsx/.png` 等路径（辅助手段）

3. **SSE 文件事件**：检测到新文件后追加到流末尾
   ```
   event: file
   data: {"name":"report.pdf","path":"report.pdf","size":245760,"type":"application/pdf"}
   ```

**前端实现：**

文件卡片组件（嵌入聊天消息气泡中）：

```
┌────────────────────────────┐
│  📄 report.pdf             │
│  240 KB · PDF 文档          │
│  [预览]  [保存到手机]       │
└────────────────────────────┘
```

- 预览：`QLPreviewController`（iOS 原生，支持 PDF/Office/图片/音视频）
- 保存：`UIActivityViewController`（分享到"文件"App/微信/邮件等）

> **阶段**：Phase 1 实现。文件生成是 Agent 基础能力，用户看到"已生成报告"但拿不到文件，体验严重缺失。

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

### 9.4 Stop 按钮（中断 AI 响应）

AI 推理和回复过程可能耗时较长（尤其涉及工具调用链时），用户需要随时中断的能力。

**UI 设计**：

```
┌─ AI 推理气泡 ──────────────────── ■ ┐
│  正在思考...                         │
│  （浅色推理文字流式输出中）            │
└──────────────────────────────────────┘
                                    ↑ Stop 按钮（方块图标）
```

- 推理/回复进行中时，在消息气泡右上角或下方显示 ■（方块）Stop 按钮
- 点击后的处理流程（**前端即停，后端异步**）：
  1. **前端立即**：中断 SSE 流（`URLSessionDataTask.cancel()`），停止渲染，已接收内容保留并标记"已中断"
  2. **前端 fire-and-forget**：发送 `POST /api/v2/chat/cancel`，不等待响应
  3. **后端异步**：收到 cancel 后关闭对 OpenClaw 的请求，清理资源
  4. 用户**零等待**，点击 Stop 的瞬间 UI 就停下来
- 回复完成后 Stop 按钮自动消失

> **阶段**：Phase 1。这是聊天类产品的标配交互，ChatGPT/Claude/Kimi 均有此功能。

### 9.5 错误处理与 LLM 故障转移

**设计原则：用户永远不受挫。** 原始技术错误（如 `network connection error`）不应出现在用户面前。

#### 错误包装层

所有后端/网络错误统一包装为用户友好的提示：

| 原始错误 | 用户看到的 | 系统行为 |
|---|---|---|
| `network connection error` | "网络波动，正在重试..." | 自动重试（见下） |
| LLM 超时（>30s 无响应） | "AI 思考时间过长，正在切换..." | 切换备用 LLM 重试 |
| LLM 返回空/异常 | "AI 回复异常，正在重试..." | 切换备用 LLM 重试 |
| 后端 500 | "服务暂时繁忙，请稍后再试" | 记录日志，不自动重试 |
| JWT 过期 / 401 | "登录已过期" + 自动跳转登录 | 前端清除 token，重新认证 |
| 容器未启动 | "正在启动你的 AI 助手..." | 自动启动容器 + warmup |

#### LLM 故障转移（自动重试）

当主力 LLM 失败时，静默切换到备用模型重试，用户可能完全感知不到出错：

```
用户发送消息
  → 请求 DeepSeek V3.2（主力）
  → 失败（超时/网络错误/异常响应）
  → 前端显示"正在重试..."（轻量提示，非弹窗）
  → 自动切换 GLM-5（备用）重试
  → 成功 → 正常输出回复
  → 仍失败 → 切换免费模型（MiMo/GLM Flash）再试一次
  → 仍失败 → 显示"AI 暂时不可用，请稍后再试"
```

**实现方式：OpenClaw 原生 fallback（无需自建）**

OpenClaw 网关层已内置完整的模型故障转移机制，只需在 `openclaw.json` 中配置 `fallbacks` 数组：

```json5
{
  agents: {
    defaults: {
      model: {
        primary: "zenmux/deepseek/deepseek-chat",       // 主力
        fallbacks: [
          "zenmux/z-ai/glm-4.6v-flash-free",            // 备用（免费）
          "zenmux/xiaomi/mimo-v2-flash"                  // 兜底（免费）
        ]
      }
    }
  }
}
```

**OpenClaw 故障转移流程（自动，无需代码）：**

```
请求 → DeepSeek V3.2（主力）
         ↓ 失败（超时/网络/限流）
       → GLM 4.6V Flash（备用）
         ↓ 仍失败
       → MiMo V2 Flash（兜底）
         ↓ 仍失败
       → 返回错误 → proxy.py 包装为友好提示
```

**OpenClaw 还内置 Auth Cooldown 机制：**
- 某个模型/provider 失败 → 自动指数退避冷却（1min → 5min → 25min → 1h 封顶）
- 冷却状态持久化到 `auth-profiles.json`，重启后仍生效
- 同一 session 内粘住同一个 auth profile（缓存友好），直到失败才切换

**这意味着**：
- **不需要在 proxy.py 中自建 fallback 逻辑** — OpenClaw 网关层已处理
- proxy.py 只需做**错误包装**：将 OpenClaw 最终返回的错误转为友好提示
- 切换模型对用户完全透明，回复质量可能略有差异但服务不中断
- 所有切换记录在 OpenClaw 日志中，可用于分析 LLM 稳定性

> **阶段**：Phase 1（与 Stop 按钮、文件下载同批实现）。错误体验直接决定用户留存率。

### 9.6 已知前端问题（已修复）

| 问题 | 根因分析 | 修复方案 | 状态 |
|---|---|---|---|
| **对话区偶尔刷新空白** | 用户点击发送后，前端同时做两件事：① 添加用户消息 + 占位气泡（触发 SwiftUI 重绘 + 动画）；② 立即发起 SSE 请求。后端推理事件在前端重绘未完成时就开始涌入，造成 `LazyVStack` 在 reconciliation 期间短暂清空 | **Ready Gate 机制**：前端必须处于 "ready" 状态后才向后端发请求。具体实现：占位气泡 `onAppear` 作为 ready 信号 → `CheckedContinuation` 等待 → 确认气泡已渲染 → 才发起 SSE 流式请求。附带 500ms 安全超时防死锁。同时流式滚动使用无动画模式避免队列堆积 | ✅ 已修复 |

> **设计哲学**：以用户体验为第一诉求。不在前端未就绪时浪费后端资源，省下的算力留给未来的记忆机制。如果 ready gate 不足以解决流式期间的卡顿，再考虑加入事件节流机制。

### 9.7 滚动到底部浮动按钮

当对话区内容超出一屏，且用户不在底部时，在对话区右下角显示一个圆形向下箭头按钮，点击后平滑滚动到最新消息。

- **检测机制**：在 `LazyVStack` 末尾放置一个 1pt 不可见锚点（`Color.clear.frame(height: 1)`），利用 SwiftUI 的 `onAppear` / `onDisappear` 判断底部是否在可见区域
- **UI 设计**：36×36 圆形按钮，`chevron.down` 图标，半透明主题色背景 + 阴影，出现/消失带 opacity + scale 动画
- **滚动行为**：点击按钮触发带动画的 `scrollTo("bottom-anchor")`，滚动完成后按钮自动消失

### 9.8 前端性能优化（流式渲染）

> 更新：2026-02-17

流式 SSE 期间，每个 chunk 都触发 SwiftUI 状态变更、全量 Equatable diff 和滚动，导致 UI 卡顿。通过以下优化将 UI 更新频率从每 chunk 一次降至约 10 次/秒：

| 优化项 | 问题 | 方案 | 效果 |
|---|---|---|---|
| **流式节流** | 每个 SSE chunk 触发一次 `@State` 变更 | 本地缓冲 `pendingContent/pendingThinking`，每 100ms 批量刷新一次 UI | 更新频率降 90%+ |
| **缓存索引** | 每个 chunk 做 O(n) `firstIndex` 查找 | placeholder append 后缓存 `cachedIdx = messages.count - 1` | O(1) 直接访问 |
| **自定义 Equatable** | `Message` 默认 Equatable 比较 `Attachment.data`（大二进制） | 自定义 `==`：仅比较 `id, content, thinkingText, status, isStreaming, role` | diff 成本降 90%+ |
| **图片异步解码** | `UIImage(data:)` 在 body 内同步解码阻塞主线程 | 改用 `@State decodedImage` + `.task` 后台解码 + 占位 ProgressView | 主线程零阻塞 |
| **MessageStore 异步加载** | `@State` 初始化时同步 `FileManager.read` | 改为空数组初始化 + `.task { MessageStore.load() }` | 启动不卡顿 |

### 9.9 内容安全过滤

> 更新：2026-02-17

当 DeepSeek LLM 因上下文中存在敏感内容而返回 0-chunk 空响应时：

1. **后端检测**：`proxy.py` 在 `data: [DONE]` 时检查 `chunk_count == 0`
   - 对话历史 > 4 条消息 → 判定为内容安全过滤，发送 `filtered` 事件
   - 对话历史 ≤ 4 条消息 → 判定为实例启动问题，发送普通错误提示
2. **前端响应**：收到 `filtered` 事件后自动清理最近 2 轮对话（4 条消息），显示临时提示
3. **历史防御**：`ChatService.buildRequestMessages()` 自动跳过 `.error` 和 `.filtered` 状态的消息

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

### 10.3 后端对话全量持久化

> 更新：2026-02-17。为未来的记忆梳理机制奠定数据基础。

**`chat_logs` 表结构：**

| 字段 | 类型 | 说明 |
|---|---|---|
| `id` | UUID PK | 每条记录唯一 ID |
| `user_id` | FK → users.id | 用户标识 |
| `event_id` | UUID (indexed) | 同一请求-响应对共享，关联完整对话轮次 |
| `role` | String | `user` 或 `assistant` |
| `content` | Text | 完整对话原文 |
| `thinking_text` | Text (nullable) | AI 思考过程文本（tool 状态等） |
| `attachment_paths` | Text (nullable) | JSON 数组，文件引用路径 |
| `tool_calls` | Text (nullable) | JSON 数组，工具名称和参数摘要 |
| `status` | String | `success` / `error` / `filtered` |
| `model` | String (nullable) | 使用的 LLM 模型 |
| `created_at` | DateTime (tz) | UTC 时间戳 |

**采集时机：**

1. 请求到达 → 立即写入用户消息（`role=user`）
2. SSE 流结束 → `_logged_stream` wrapper 累积完整 AI 回复后写入（`role=assistant`）
3. 非流式请求 → 响应返回后写入

**设计原则：**

- 日志写入失败不影响聊天功能（fire-and-forget，异常仅记录日志）
- 使用独立 DB session，不与请求 session 耦合
- 每次请求生成唯一 `event_id`，可按 event_id 关联请求-响应对

**后续用途：**

- `GET /api/v2/chat/history` — 分页拉取历史（替代前端 50 条本地缓存限制）
- 按 user_id + 时间范围统计对话量/token 消耗
- 为记忆梳理机制提供原始语料库（自动提取关键信息 → MEMORY.md）

### 10.4 文件下载与 Workspace Diff

> 更新：2026-02-18。实现 Agent 生成文件 → 用户手机的完整链路。

**后端实现：**

1. **下载 API**：`GET /api/v2/files/download?path={relative_path}&token={jwt}`
   - 支持 URL 参数 token（主）和 Authorization header（备），兼容 CDN 场景
   - `is_relative_to()` 路径穿越防护 + 自动推断 MIME type + FileResponse 流式返回
2. **Workspace Diff**：`proxy_chat_stream()` 在 SSE 流开始前快照 workspace 目录（文件名+size+mtime），`[DONE]` 之前再次扫描，对比找出新增/修改文件
   - 使用 `os.walk` + 目录剪枝（排除 `venv/node_modules/__pycache__` 等），性能从 1069ms 降至 1.1ms
3. **SSE File 事件注入**：新增/修改的文件以 `{"choices":[{"delta":{"file":{...}}}]}` 格式注入 SSE 流末尾
4. **图片内联 Base64**：对 ≤512KB 的图片文件，在 SSE file 事件中嵌入 base64 编码的完整图片数据（`data` 字段），前端无需额外下载
5. **排除规则**：`media/inbound/`（用户上传）、`memory/`、`skills/`、隐藏文件/目录

**CDN 兼容性设计：**

```
问题：Cloudflare/DNSPod 对 GET 文件下载请求返回 HTML 屏蔽页（<!DOCTYPE...），
     而非转发后端的二进制响应。POST 请求（SSE 流）不受影响。

诊断依据：前端 debug 显示 data:16734b UIImage=nil hex:3c21444f43545950
          （3c21444f43545950 = "<!DOCTYP" — 收到了 HTML 而非 PNG）

解决方案：将图片数据嵌入 SSE file 事件（base64），复用 POST 流通道，
          完全绕过 CDN 对 GET 的干扰。非图片文件仍走下载 API。
```

**前端实现：**

| 组件 | 职责 |
|------|------|
| `FileInfo` 模型 | workspace 文件元数据（name/path/size/mimeType/inlineData），支持 Codable |
| `StreamEvent.file` | SSE 解析层新增的文件事件 case |
| `FileDownloader` actor | 文件下载 + 图片内存缓存 + 401 自动刷新重试 + Content-Type 校验（防 HTML 误判） |
| `FileCardView` | 图片 → 优先使用 SSE 内联 base64（降级为 HTTP 下载）+ 3 次重试 + 缩略图展示；非图片 → SF Symbol + 文件名 + 大小卡片 |
| `FullScreenImageViewer` | 全屏图片查看器：捏合缩放（MagnificationGesture，iOS 16+）+ 双击缩放 + 拖动关闭 |
| `FilePreviewSheet` | QLPreviewController 封装，支持 PDF/Office/图片/音视频预览 |
| `ShareSheet` | UIActivityViewController 封装，支持保存到手机/分享 |

### 10.5 对话区 Markdown 富文本渲染

> 更新：2026-02-17。将 AI 回复从纯文本升级为 Markdown 渲染。

- **依赖**：[MarkdownUI](https://github.com/gonzalezreal/swift-markdown-ui) 2.4.1（SPM）
- **渲染范围**：仅 assistant 消息渲染 Markdown，用户消息保持纯文本
- **自定义主题** `clawBowlAssistant`：
  - 文本 16pt + primary 颜色，代码块 monospaced 等宽字体 + 灰色背景 + 横向滚动
  - 标题 H1/H2/H3 差异化字号，引用块左侧竖线 + 斜体
  - 链接蓝色可点击
- **流式兼容**：当前 proxy 将整轮 content 在 `finish_reason: "stop"` 时一次性发送，不存在 partial markdown 问题

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

### 12.1 设计哲学

> **使用率是 App 的生命线。** 在成本可控的前提下，最大化用户粘度。
>
> - **永不限制使用**：免费用户也能无限对话，不设日消息上限
> - **永不降智**：所有用户使用同等级的 LLM，AI 的"脑子"不分三六九等
> - **成本控制靠容器规模**：免费用户的容器小一些（记忆、存储），成本天然可控
> - **接近上限时优化而非限制**：Agent 自动压缩/归档旧记忆，用户无感
>
> 这恰好与"数字灵魂"隐喻吻合：
> - **Free = 年轻的灵魂**：脑子一样聪明，但记忆容量小，旧记忆会被压缩归档
> - **Pro = 成熟的灵魂**：更大的记忆空间，能做更多自动化
> - **Premium = 完整的灵魂**：无限记忆，完整自动化，旗舰推理

### 12.2 成本结构

| 成本项 | 月费用/用户 | 说明 |
|---|---|---|
| 容器（CPU + 内存） | ≈ ¥5-15 | 极低，Free 用户给小容器即可控制 |
| 存储 | ≈ ¥1-3 | 可忽略 |
| LLM token（中端模型） | ≈ ¥10-50 | DeepSeek V3.2 / GLM-5，所有用户共享 |
| 搜索 API | ≈ ¥5-10 | Tavily / Kimi 搜索 |

> **关键**：国内中端模型（DeepSeek V3.2 输入 $0.28/M，GLM-5 输入 $0.11/M）成本极低。即使免费用户每天对话 100 次，月 token 成本也仅 ¥5-15。这个成本可以通过广告、增值服务或小容器资源节省来覆盖。

### 12.3 订阅分级

**所有级别共享的核心体验**（不分级的部分）：

| 类别 | 能力 | 说明 |
|---|---|---|
| LLM 模型 | DeepSeek V3.2 / GLM-5 等中端模型 | **所有用户同等智力水平** |
| 对话 | **无限** | 不限日消息数，使用率是生命线 |
| 文件操作 | read / write / edit / exec | 全量开放 |
| 记忆系统 | MEMORY.md + 日记 + memory_search | 完整（容量因级别不同） |
| 网页搜索 | Tavily + 基础搜索 | 全量开放 |
| 多模态 | 图片识别 | 全量开放 |
| 消息通道 | 仅 App | 设计决策 |
| 备份 | 每日自动 Snapshot | 至少保留 3 个 |

#### Free —— 年轻的灵魂

零成本，通过限制容器规模控制成本。AI 智力不打折。

| 类别 | 规格 | 说明 |
|------|------|------|
| **容器** | CPU 0.5 核 / 内存 512MB / 存储 200MB | 小容器，成本极低 |
| **记忆容量** | 记忆文件上限 10MB（约 3-6 个月日记） | 超限时 Agent 自动归档压缩旧记忆 |
| **workspace** | 100MB | 超限时 Agent 自动清理临时文件 |
| 自动化 | 无 | cron/heartbeat 禁用 |
| 浏览器 | 无 | 禁用（节省内存） |
| 技能 | 内置 + 3 个自定义 | — |
| 备份 | 每 24 小时 | 保留 3 个 |

**记忆容量上限策略**（免费用户的核心成本控制机制）：

```
记忆文件接近 10MB 上限时：
  1. Agent 自动触发记忆整理
  2. 将 30 天前的日记压缩为摘要（如 5 篇日记 → 1 段摘要）
  3. 清理 workspace 中的临时文件
  4. 更新 MEMORY.md 中的长期记忆索引
  → 用户无感，AI 仍然"记得"重要的事，只是细节更概括
```

#### Pro —— 成熟的灵魂

核心价值：更大的灵魂容量 + 自动化 + 浏览器。

| 类别 | 规格 | 说明 |
|------|------|------|
| **容器** | CPU 1 核 / 内存 1.5GB / 存储 1GB | — |
| **记忆容量** | 记忆文件上限 50MB（约 2 年日记） | 更丰富的长期记忆 |
| **workspace** | 500MB | — |
| 自动化 | cron + heartbeat | 最多 5 个定时任务 |
| 浏览器 | 基础自动化 | 单标签页 |
| 技能 | 全部 + 社区技能 | 无限 |
| 备份 | 每 5 分钟 | 保留 30 个 |
| 旗舰模型（可选） | 加购：Kimi K2.5 / DeepSeek Reasoner 按量计费 | 复杂任务按需使用 |

#### Premium —— 完整的灵魂

核心价值：无限灵魂容量 + 旗舰推理 + 完整自动化。

| 类别 | 规格 | 说明 |
|------|------|------|
| **容器** | CPU 1 核 / 内存 2GB / 存储 2GB | 系统自动伸缩 |
| **记忆容量** | **无限** | 完整的生命记忆 |
| **workspace** | 2GB | — |
| **旗舰模型** | Kimi K2.5 / DeepSeek Reasoner 等 | **包含在订阅内** |
| **输出长度** | max_tokens: 16384 | — |
| 自动化 | cron + heartbeat | 无限 |
| 浏览器 | 完整自动化 | 多标签页 |
| 技能 | 全部 | — |
| 备份 | 每 1 分钟 | 无限 |

### 12.4 资源优化策略（替代"限制/降智"）

用户**永远不会被限制使用**，系统通过优化来控制成本：

| 场景 | 传统做法（❌） | ClawBowl 做法（✅） |
|---|---|---|
| 免费用户对话多 | 限制 50 条/天 | **不限制**，中端模型 token 成本极低 |
| 记忆空间满 | 停止记录新记忆 | **Agent 自动归档压缩**旧记忆为摘要 |
| 存储空间满 | 禁止写入 | **Agent 自动清理**临时文件 + 通知用户 |
| 用户长期不活跃 | 删除账户 | **容器休眠**（停止但不删除），唤醒后秒级恢复 |
| Pro 用户想用旗舰模型 | 升级到 Premium | **按量加购**，不强制升级整个套餐 |

> **核心理念**：永远不要让用户感觉"被限制了"。优化是 AI 的工作，不是用户的负担。

---

## 13. 安全边界

容器必须：
- 非 privileged
- 无宿主机敏感目录挂载
- 资源上限按订阅级别（Free: 0.5 核/512MB → Premium: 1 核/2GB），防止单容器耗尽宿主机
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

### 14.1 OpenClaw 内核隔离性评估

> 更新：2026-02-18。Phase 0 完成后的架构隔离确认。

**核心结论：所有 Phase 0 改动均未触碰 OpenClaw 内核代码，OpenClaw 可平滑升级。**

ClawBowl 的三层架构天然保证了隔离性：

```
┌─ iOS App（SwiftUI）──────────────────────────────────┐
│  FileCardView / FileDownloader / FullScreenImageViewer │  ← 我们的代码
│  ChatView / MessageBubble / MarkdownUI                 │  ← 我们的代码
└────────────────────────────────────────────────────────┘
          ↕ HTTPS + SSE
┌─ Backend Proxy（FastAPI）─────────────────────────────┐
│  proxy.py: 日期注入 / workspace diff / SSE file 事件   │  ← 我们的代码
│  file_router.py: 文件下载 API                          │  ← 我们的代码
│  chat_router.py: 对话持久化 / 流式包装                  │  ← 我们的代码
│  auth.py: JWT 认证                                     │  ← 我们的代码
└────────────────────────────────────────────────────────┘
          ↕ HTTP (OpenAI 兼容 API)
┌─ OpenClaw Container（Docker）────────────────────────┐
│  openclaw gateway --bind lan --port 18789             │  ← 未修改
│  /usr/lib/node_modules/openclaw (bind mount)          │  ← 未修改
│  /data/config/openclaw.json                           │  ← 仅配置
│  /data/workspace/                                     │  ← Agent 工作区
└────────────────────────────────────────────────────────┘
```

**逐项确认：**

| 类别 | 文件 | 是否触碰 OpenClaw 内核 | 说明 |
|------|------|----------------------|------|
| iOS 前端 | `ClawBowl/*.swift`（15 个文件） | ❌ 完全独立 | SwiftUI 纯前端，通过 HTTPS 与后端通信 |
| 后端代理 | `backend/app/**/*.py`（15 个文件） | ❌ 完全独立 | FastAPI 服务，通过 HTTP 转发到 OpenClaw |
| OpenClaw 配置 | `openclaw.json` | ❌ 仅配置 | 模型/fallback/工具开关，属于正常运维操作 |
| OpenClaw Node.js 代码 | `/usr/lib/node_modules/openclaw/` | ❌ 未修改 | bind mount 只读挂载，容器内代码完全原版 |
| OpenClaw Docker 镜像 | `clawbowl-openclaw:latest` | ❌ 未修改 | 基于官方镜像构建，未 patch 任何源码 |
| Workspace 文件 | `AGENTS.md / SOUL.md / MEMORY.md` | ❌ 配置级 | Agent 行为规则，属于用户数据层，非内核 |

**升级路径**：`docker pull` 新版 OpenClaw → 停旧容器 → 启新容器（复用 config + workspace bind mount）→ 健康检查。我们的所有改动（proxy / iOS / 下载 API）对 OpenClaw 完全透明。

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

### 17.3 ZenMux 可用国内模型清单

> 更新时间：2026-02-17

ZenMux 是 ClawBowl 当前的 LLM 聚合层，通过统一的 OpenAI 兼容接口接入多家国内模型。以下为完整清单：

#### 深度求索（DeepSeek）

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| DeepSeek V3.2 (Non-thinking) | `deepseek/deepseek-chat` | 纯文本 | 关闭 | 128K | $0.28 / $0.42 | **当前主模型** |
| DeepSeek V3.2 (Thinking) | `deepseek/deepseek-reasoner` | 纯文本 | 始终开启 | 128K | $0.28 / $0.42 | 推理模式 |
| DeepSeek V3.2 | `deepseek/deepseek-v3.2` | 纯文本 | 始终开启 | 128K | $0.28 / $0.43 | — |

#### 智谱清言（Z.AI / GLM）

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| GLM 4.7 | `z-ai/glm-4.7` | 纯文本 | 可切换 | 200K | $0.28 / $1.14 | 最新旗舰，Agent+编程增强 |
| GLM 4.6V | `z-ai/glm-4.6v` | **图片** ✅ | 可切换 | 200K | $0.14 / $0.42 | 原生 tool call + 视觉 |
| GLM 4.6V FlashX | `z-ai/glm-4.6v-flash` | **图片** ✅ | 可切换 | 200K | **免费** | 限时免费，容量更高 |
| GLM 4.6V Flash (Free) | `z-ai/glm-4.6v-flash-free` | **图片** ✅ | 可切换 | 200K | **免费** | **当前 imageModel** |

#### 字节跳动 / 火山引擎（豆包 Doubao）

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| Doubao-Seed-1.8 | `volcengine/doubao-seed-1.8` | **图片** ✅ | 可切换 | 256K | $0.11 / $0.28 | 多模态 Agent，性价比高 |
| Doubao-Seed-Code | `volcengine/doubao-seed-code` | 纯文本 | 可切换 | 256K | $0.17 / $1.12 | 编程专用，SWE-Bench 领先 |

#### 小米（Xiaomi）

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| MiMo V2 Flash | `xiaomi/mimo-v2-flash` | 纯文本 | 可切换 | 262K | **免费** | **当前在用**，309B MoE，SWE-Bench 开源 #1 |
| MiMo V2 Flash Free | `xiaomi/mimo-v2-flash-free` | 纯文本 | 可切换 | 262K | **免费** | 有速率限制 |

#### 月之暗面（Moonshot / Kimi）

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| Kimi K2 Thinking | `moonshotai/kimi-k2-thinking` | 纯文本 | 始终开启 | 262K | $0.60 / $2.50 | 深度推理 |
| Kimi K2 Thinking Turbo | `moonshotai/kimi-k2-thinking-turbo` | 纯文本 | 始终开启 | 262K | $1.15 / $8.00 | 高速版 |

#### 百度（Baidu / ERNIE 文心）

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| ERNIE 5.0 Thinking | `baidu/ernie-5.0-thinking-preview` | **图片+音频+视频** ✅ | 始终开启 | 128K | $0.84 / $3.37 | 原生多模态最全，支持音频/视频 |

#### MiniMax

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| MiniMax M2.1 | `minimax/minimax-m2.1` | 纯文本 | 始终开启 | 205K | $0.30 / $1.20 | 10B 激活参数，编程+Agent 强 |

#### 阿里（Qwen 通义千问）

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| Qwen3-Coder-Plus | `qwen/qwen3-coder-plus` | 纯文本 | — | — | — | 编程专用 |

#### inclusionAI

| 模型 | ZenMux ID | 多模态 | 推理模式 | 上下文 | 价格 (输入/输出 $/M) | 备注 |
|------|-----------|--------|---------|--------|---------------------|------|
| LLaDA2-flash-CAP | `inclusionai/llada2.0-flash-cap` | 纯文本 | — | 32K | $0.28 / $2.85 | 100B MoE 扩散架构 |

#### 多模态能力汇总

| 模型 | 文本 | 图片 | 音频 | 视频 | 价格 |
|------|------|------|------|------|------|
| GLM 4.6V 系列 | ✅ | ✅ | ❌ | ❌ | 免费 |
| Doubao-Seed-1.8 | ✅ | ✅ | ❌ | ❌ | $0.11 |
| ERNIE 5.0 | ✅ | ✅ | ✅ | ✅ | $0.84 |
| 其他所有 | ✅ | ❌ | ❌ | ❌ | 各异 |

> **注**：豆包的语音/视频能力在火山引擎有独立 API（实时语音模型、TTS、ASR），但在 ZenMux 的 chat completions 接口中，Doubao-Seed-1.8 仅支持图片输入，不支持音频/视频。

### 17.4 ClawBowl 的 LLM 策略

#### 当前 OpenClaw 配置

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

### 17.5 时效性数据问题与联网 LLM 评估

> 更新：2026-02-18

#### 问题描述

当前 Agent 使用的 LLM（DeepSeek V3.2 等）没有实时联网能力。虽然 proxy.py 注入了日期上下文使 Agent 知道"今天是 2026-02-18"，但 LLM 的训练数据存在截止日期，导致以下问题：

```
用户："显示近 5 个月比特币价格走势图"
Agent 行为：
  1. ✅ 正确推算日期区间（2025-09 ~ 2026-02）
  2. ❌ 从训练数据中取出过时价格（非真实行情）
  3. ❌ 用过时价格 + 正确日期生成图表 → 误导用户
```

**根因**：日期注入只解决了"Agent 不知道今天几号"的问题，没有解决"Agent 的知识库是过时的"问题。对于实时性数据（股价、天气、新闻），LLM 应该使用 `web_search` 工具获取数据，而非依赖训练数据。

#### 方案对比

| 方案 | 原理 | 优点 | 缺点 | 可行性 |
|------|------|------|------|--------|
| **A. 强化提示词** | 在 AGENTS.md 中明确要求"任何实时性数据必须先 web_search" | 零成本、零改动 | 依赖 LLM 遵循指令，非 100% 可靠 | ⭐⭐⭐ 推荐先做 |
| **B. ZenMux Web Search** | 在 API 请求中加 `web_search_options` 参数 | ZenMux 原生支持、支持所有模型 | 额外成本、增加延迟、与 OpenClaw 内置 web_search 工具可能冲突 | ⚠️ 架构冲突 |
| **C. OpenRouter :online** | 模型 slug 加 `:online` 后缀启用搜索 | 31 个免费模型可用 | 20 req/min 限流、Exa 搜索额外收费、国内模型选择少 | ⚠️ 限制多 |
| **D. 仅用联网 LLM** | 只使用原生支持联网的模型 | 数据最准确 | 国内免费联网 LLM 几乎不存在；大幅缩小模型选择范围 | ❌ 不可行 |

#### OpenRouter vs ZenMux 联网能力对比

| 维度 | OpenRouter | ZenMux |
|------|------------|--------|
| **联网机制** | 模型 slug 加 `:online` 后缀 | `web_search_options` 请求参数 |
| **支持的国内免费模型** | Qwen3 系列、GLM-4.5-Air、StepFun | 需确认（文档未列出免费联网模型） |
| **搜索引擎** | Exa（非原生模型）/ 原生（OpenAI/Anthropic） | 自建搜索服务，支持地理位置过滤 |
| **免费额度** | 搜索本身收费（即使模型免费） | 搜索本身收费 |
| **免费模型限流** | 20 req/min, 200 req/day | 未公开 |
| **已接入 ClawBowl** | ❌ 未接入 | ✅ 已接入 |
| **与 OpenClaw 兼容性** | 需改 proxy 添加 `:online` | 需改 proxy 添加 `web_search_options` |

#### 推荐策略：A + 监控

**短期（Phase 0/1）**：强化 AGENTS.md 提示词，要求 Agent 对时效性查询强制使用 `web_search` 工具。这利用了 OpenClaw 已有的 Tavily 搜索能力，零成本零改动。

```markdown
# AGENTS.md 新增规则
## 实时数据规则
对于以下类型的查询，你必须先使用 web_search 工具获取最新数据，禁止使用训练数据：
- 股票/加密货币/汇率等金融数据
- 天气预报
- 新闻/时事
- 产品价格/库存
- 体育赛事比分
- 任何用户明确要求"最新"或"当前"的信息
```

**中期（Phase 3）**：如果提示词方案不够可靠，再考虑在 proxy 层为特定场景（如检测到金融/天气关键词）自动启用 ZenMux `web_search_options`。

**不推荐**：完全剔除非联网 LLM。原因：
1. 国内免费联网 LLM 几乎不存在——联网能力都需额外付费
2. OpenClaw 已有 `web_search`（Tavily）+ `web_fetch` 工具链，Agent 本身具备联网能力
3. 问题本质是 Agent 行为（该搜不搜），不是 LLM 能力（能不能搜）

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
| **前端流式性能优化** | SSE 节流（100ms 批量刷新）+ 自定义 Equatable + 图片异步解码 + 异步加载 | ✅ |
| **对话全量持久化** | chat_logs 表：user_id / event_id / 对话原文 / 工具调用 / 文件指针 / 状态；SSE 中断亦持久化（try/finally） | ✅ |
| **内容安全过滤** | 0-chunk 检测 → filtered 事件 → 前端自动清洗上下文 + 后端保留审计记录 | ✅ |
| **文件下载** | workspace diff → SSE file 事件 → 前端 FileCardView + QLPreview + ShareSheet | ✅ |
| **图片内联展示** | SSE file 事件携带 base64 内联数据（≤512KB），前端直接解码为缩略图，点击全屏查看原图 | ✅ |
| **Markdown 富文本渲染** | MarkdownUI 2.4.1，assistant 消息渲染 Markdown（代码块/标题/链接/引用），自定义 clawBowlAssistant 主题 | ✅ |
| **Workspace Diff 优化** | os.walk + 目录剪枝（排除 venv/node_modules 等），快照性能从 1069ms → 1.1ms | ✅ |
| **Agent 时间感知** | system 消息 + 用户消息双重注入当前 UTC 日期/年份（已知局限见 17.5 节） | ✅ |
| **CDN 兼容性** | Cloudflare 拦截 GET 文件请求 → 改为 SSE 内联 base64 传输图片，彻底绕过 CDN | ✅ |
| **错误包装 + LLM 故障转移** | openclaw.json fallbacks + proxy.py 错误包装 + 前端兜底 | ✅ |

### Phase 1 — 自主能力 + 基础备份（下一步）

目标：agent 从"被动回答"进化为"主动行动"，同时建立数据安全网。

| 能力 | 实现方式 | 前端改动 | 后端改动 | 优先级 |
|---|---|---|---|---|
| ~~**文件下载**~~ | 下载 API + SSE file 事件（详见 8.4） | FileCardView + 预览/分享 | `/api/v2/files/download` + workspace diff | ✅ 已完成 |
| ~~**对话区富内容展示**~~ | MarkdownUI 渲染 + 图片内联 + 文件卡片 | Markdown 主题 + FileCardView + FileDownloader | SSE file delta 注入 | ✅ 已完成 |
| **基础 Snapshot** | tar.zst + manifest.json（详见第 6 章） | 无 | 定时任务 + 控制面 API | ⭐⭐⭐ |
| **Cron 定时任务** | 启用 cron 工具 + HEARTBEAT.md | 添加"定时任务"管理 UI | openclaw.json 启用 cron | ⭐⭐⭐ |
| **Heartbeat 心跳** | 配置 heartbeat 周期 | 无（后台自动） | HEARTBEAT.md 配置检查项 | ⭐⭐⭐ |
| **Stop 按钮** | 中断 SSE 流 + 取消后端请求 | 推理气泡旁 ■ 按钮 | `/api/v2/chat/cancel` | ⭐⭐⭐ |
| ~~**对话区空白修复**~~ | Ready Gate：占位气泡 onAppear → 才发请求 | ChatView ready gate + 无动画滚动 | 无 | ✅ 已完成 |
| ~~**滚动到底部按钮**~~ | 底部锚点 + 浮动箭头 | ChatView 悬浮按钮 | 无 | ✅ 已完成 |
| **子 Agent 派生** | sessions_spawn（ping-pong） | 无（透明执行） | 启用 session tools | ⭐⭐ |
| **APNs 系统推送** | APNs HTTP/2 + JWT + alert_monitor | NotificationManager + AppDelegate | apns_service + alert_monitor + device_token API | ⭐⭐⭐ |
| **ClawHub 技能** | 安装社区技能到 workspace/skills/ | 添加"技能市场"入口 | 无（agent 自行安装） | ⭐⭐ |

> **为什么基础备份必须在 Phase 1？** 启用 cron/heartbeat 后 Agent 开始自主行动，如果出错必须能回滚。没有备份就启用自动化 = 裸奔。

> **为什么 APNs 推送是 Phase 1 核心能力？** OpenClaw 挂接 Telegram/Discord 等聊天平台时，推送能力完全受限于第三方——Agent 只能在对话流中回复，用户必须主动打开聊天窗口才能看到。独占 App + APNs 实现了系统级通知（锁屏、横幅、通知中心），这是 ClawBowl 相对于"OpenClaw + 任何第三方聊天工具"方案的**不可替代差异化能力**，是 Agent 从"被动问答"到"主动服务"的关键闭环。

**APNs 推送架构**：
```
Cron 定时任务 → Agent 执行检测 → 写入 workspace/.alerts.jsonl
  → Backend alert_monitor 每 60s 轮询
  → apns_service HTTP/2 + JWT → Apple APNs → iPhone 系统推送
  → 用户点击通知 → App CronView
```

**预期效果**：
- 用户说"每天早上 9 点帮我查天气" → agent 自动创建 cron
- Agent 定期自主检查记忆、整理笔记
- 复杂任务自动拆解为子任务
- 任何操作出错 → 可从最近快照恢复
- **Cron 检测到异常（如 BTC 波动 >1%）→ 即使 App 未打开，用户也收到系统推送**

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

**已完成** ✅（Phase 0）：
1. ~~容器目录结构~~
2. ~~多模态文件 inbox 机制~~
3. ~~持久会话 + 记忆系统~~
4. ~~推理过程/最终结果分离~~
5. ~~TOOLS.md 自动维护~~
6. ~~**前端流式性能优化**~~（✅ SSE 节流 100ms + 自定义 Equatable + 图片异步解码 + 异步加载）
7. ~~**对话全量持久化**~~（✅ chat_logs 表 + SSE 中断 try/finally 保障）
8. ~~**内容安全过滤**~~（✅ 0-chunk 检测 + filtered 事件 + 前端自动清洗 + 后端审计保留）
9. ~~**错误包装 + LLM 故障转移**~~（✅ openclaw.json fallbacks + proxy.py 错误包装 + 前端兜底）
10. ~~**文件下载功能**~~（✅ 下载 API + workspace diff + SSE file 事件 + CDN base64 内联）
11. ~~**对话区富内容展示**~~（✅ MarkdownUI + 图片缩略图/全屏查看 + 文件卡片 + QLPreview）
12. ~~**修复对话区刷新空白 Bug**~~（✅ Ready Gate 机制）
13. ~~**滚动到底部浮动按钮**~~（✅ 底部锚点 + 浮动箭头）
14. ~~**Workspace Diff 性能优化**~~（✅ os.walk + 目录剪枝，1069ms → 1.1ms）
15. ~~**Agent 时间感知**~~（✅ system + user 双重日期注入，已知局限见 17.5）
16. ~~**CDN 兼容性**~~（✅ Cloudflare HTML 拦截 → SSE 内联 base64 绕过）

**立即做**（Phase 1）：
1. **Stop 按钮**（前端即停，后端异步清理）
2. **基础 Snapshot 备份**（tar.zst + manifest，为后续自动化兜底）
3. 启用 Cron + Heartbeat
4. 配置 HEARTBEAT.md 自动检查项
5. 启用 sessions_spawn（子任务）
6. 前端"定时任务"管理 UI

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
