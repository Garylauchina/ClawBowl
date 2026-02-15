# ClawBowl 系统设计文档（V4）

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

## 11. OpenClaw 能力清单

### 11.1 内置工具

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

### 11.2 扩展能力

- **技能系统**：SKILL.md 注入系统提示词，ClawHub 社区技能市场
- **记忆系统**：Markdown 文件 + BM25/向量混合检索
- **插件系统**：TypeScript 模块（工具、渠道、认证等）

---

## 12. 订阅分级模型

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

## 13. 安全边界

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

## 14. 升级策略

- 不使用 `latest` tag
- 明确 `desired_version`
- 蓝绿升级
- 自动回滚
- 升级前强制 Checkpoint

---

## 15. 与 Manus 沙盒的差异

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

## 16. 技术栈

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

## 17. 产品定位与竞品差异

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

**前端收敛**：不使用 OpenClaw 的 8+ 消息通道，统一通过自有 iOS App 对接用户。
- 用户体验完全可控
- 减少多平台适配复杂度
- 用户数据完整自主

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

## 18. 国内 LLM 生态与 ClawBowl 模型策略

> 更新时间：2026-02-15

### 18.1 国内 LLM 最新格局（2026 年春节档）

2026 年春节期间，国内五大厂集中发布新一代模型，能力已接近国际第一梯队（落后约 3 个月，此前约 7 个月）。

#### 第一梯队

| 模型 | 厂商 | 参数量 | 上下文 | 核心优势 | 开源 |
|---|---|---|---|---|---|
| **DeepSeek V4**（即将发布） | 深度求索 | MoE | 1M token | 编程能力可能超越 Claude，稀疏注意力+流形约束技术 | ✅ MIT |
| **GLM-5** | 智谱 AI | 744B（40B 激活） | 200K token | Agent 能力全球第 3，幻觉率大幅降低（90%→34%），纯国产芯片训练 | ✅ MIT |
| **Kimi K2.5** | 月之暗面 | 1T | 20万+字 | 可协调 100 个子 Agent 并行，超长文本处理最强 | 部分开源 |

#### 第二梯队

| 模型 | 厂商 | 核心优势 |
|---|---|---|
| **Qwen3-Coder** | 阿里（通义千问） | 480B MoE，Agent 编程能力对标 Claude Sonnet 4，支持 358 种语言，256K-1M 上下文 |
| **Qwen3-Max-Thinking** | 阿里 | 自主工具选择（搜索/记忆/代码），测试时缩放+经验累积推理 |
| **MiniMax 2.5** | MiniMax | 轻量化（10B 激活），100 TPS 高吞吐，开发者友好 |
| **豆包 2.0** | 字节跳动 | 日活最高，语音交互最佳，多模态套件（图/视频生成） |
| **腾讯混元** | 腾讯 | 视频生成世界第一梯队 |

### 18.2 关键能力基准对比

#### 编程能力（SWE-bench Verified）

| 模型 | 得分 | 说明 |
|---|---|---|
| Claude Opus 4.5 | 80.9% | 当前天花板 |
| **GLM-5** | **77.8%** | 超越 Gemini 3 Pro (76.2%) |
| **Kimi K2.5** | **76.8%** | |
| DeepSeek V3.2 | ~74% | V4 目标突破 80% |
| Qwen3-Coder | 对标 Claude Sonnet 4 | 仓库级代码理解 |

#### Agent / 工具使用能力

| 模型 | Agent Index | 说明 |
|---|---|---|
| Claude Opus 4.5 | ~70 | 行业标杆 |
| **GLM-5** | **63** | 开源模型最高 |
| **Kimi K2.5** | — | 100 子 Agent 并行，长程任务 4.5x 加速 |
| **Qwen3-Coder** | — | RL 训练的多轮 Agent 交互 |

#### 成本（每百万 token）

| 模型 | 输入 | 输出 | 说明 |
|---|---|---|---|
| Claude Opus 4.5 | $15 | $75 | 贵 |
| GPT-5.2 | $10 | $30 | |
| **GLM-5** | **$0.11** | **$0.11** | 极低，MIT 开源 |
| **DeepSeek V3.2** | **$0.28** | **$0.42** | 低成本领跑 |
| **MiniMax 2.5** | ~$0.15 | ~$0.15 | 轻量高吞吐 |
| **Kimi K2.5** | ~$0.50 | ~$1.00 | 但推理速度快(39 tok/s) |

### 18.3 ClawBowl 的 LLM 策略

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

## 19. OpenClaw 功能激活路径

### Phase 0 — 核心基础 ✅（已完成）

| 能力 | 说明 | 状态 |
|---|---|---|
| 文本对话 | DeepSeek V3.2 via ZenMux | ✅ |
| 文件处理 | read/write/edit + exec | ✅ |
| 图片分析 | GLM 4.6V Flash 视觉模型 | ✅ |
| 通用附件 | 任意文件 → workspace → agent 处理 | ✅ |
| 网页搜索 | Brave Search（免费额度） | ✅ |
| 网页读取 | web_fetch + Readability | ✅ |
| 持久会话 | user + session-key → 跨请求复用 session | ✅ |
| 记忆系统 | MEMORY.md + memory/ 日记 + memory_search | ✅ |
| 工具记忆 | TOOLS.md 自动更新 | ✅ |
| 推理展示 | thinking 浅色字体 + 最终 content 分离 | ✅ |

### Phase 1 — 自主能力（下一步）

目标：agent 从"被动回答"进化为"主动行动"。

| 能力 | 实现方式 | 前端改动 | 后端改动 | 优先级 |
|---|---|---|---|---|
| **Cron 定时任务** | 启用 cron 工具 + HEARTBEAT.md | 添加"定时任务"管理 UI | openclaw.json 启用 cron | ⭐⭐⭐ |
| **Heartbeat 心跳** | 配置 heartbeat 周期 | 无（后台自动） | HEARTBEAT.md 配置检查项 | ⭐⭐⭐ |
| **子 Agent 派生** | sessions_spawn（ping-pong） | 无（透明执行） | 启用 session tools | ⭐⭐ |
| **ClawHub 技能** | 安装社区技能到 workspace/skills/ | 添加"技能市场"入口 | 无（agent 自行安装） | ⭐⭐ |

**预期效果**：
- 用户说"每天早上 9 点帮我查天气" → agent 自动创建 cron
- Agent 定期自主检查记忆、整理笔记
- 复杂任务自动拆解为子任务

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

| 能力 | 实现方式 | 说明 | 优先级 |
|---|---|---|---|
| **多模型切换** | LLM 管理模块 + 前端选择器 | 简单问题用免费模型，复杂问题用旗舰 | ⭐⭐⭐ |
| **Perplexity 搜索** | 配置 PERPLEXITY_API_KEY | AI 合成答案，比 Brave 更智能 | ⭐⭐ |
| **Firecrawl 反爬虫** | 配置 FIRECRAWL_API_KEY | 处理反爬虫网站 | ⭐ |
| **远程嵌入** | Gemini/OpenAI embeddings | 更精准的语义搜索 | ⭐⭐ |
| **Lobster 工作流** | 安装 Lobster CLI | 确定性流水线 + 审批门控 | ⭐ |

### Phase 4 — 平台化

目标：从单用户工具升级为可运营的平台。

| 能力 | 说明 | 优先级 |
|---|---|---|
| **订阅分级实施** | Free/Pro/Premium 模板 + 配额控制 | ⭐⭐⭐ |
| **Snapshot 版本系统** | 定期备份 + 崩溃恢复 + 蓝绿升级 | ⭐⭐⭐ |
| **Android 客户端** | Kotlin/Compose，复用后端 API | ⭐⭐ |
| **Web 客户端** | React/Vue，轻量版入口 | ⭐⭐ |
| **多用户容器编排** | K8s / Docker Swarm | ⭐ |
| **Canvas WebView** | iOS App 内嵌 WebView 替代 node Canvas | ⭐ |

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

## 20. 当前阶段实施优先级

**已完成** ✅：
1. ~~容器目录结构~~
2. ~~多模态文件 inbox 机制~~
3. ~~持久会话 + 记忆系统~~
4. ~~推理过程/最终结果分离~~
5. ~~TOOLS.md 自动维护~~

**立即做**（Phase 1）：
1. 启用 Cron + Heartbeat
2. 配置 HEARTBEAT.md 自动检查项
3. 启用 sessions_spawn（子任务）
4. 前端"定时任务"管理 UI

**1.0 后做**（Phase 2-3）：
1. Docker 镜像安装 Chromium + Playwright
2. 浏览器自动化启用
3. 多模型切换 UI
4. 远程嵌入 + Perplexity

**长期规划**（Phase 4-5）：
1. 订阅分级 + Snapshot 系统
2. 多端客户端
3. OpenClaw 模块逐步替换

**不要一开始做**：
- 分布式架构
- MicroVM
- 多 Agent 单实例迁移
- 实时双向同步
- Envelope encryption

---

## 21. 架构核心总结

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
- Tavily Search（搜索 API，已替换不可用的 Brave Search）→ 可换 SerpAPI/Bing
- 本地嵌入 / Gemini（记忆检索）→ 可换 OpenAI/Voyage
