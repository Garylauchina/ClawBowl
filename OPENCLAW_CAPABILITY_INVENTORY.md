# OpenClaw Capability Inventory

> Source: docs.openclaw.ai + github.com/openclaw/openclaw/releases
> Last updated: 2026-02-15
> Current version: **v2026.2.14** (released 2026-02-15)
> GitHub stars: 196k+ | Contributors: 50+/release

---

## 0. ClawBowl 使用状态总览

| 状态 | 含义 |
|---|---|
| ✅ 已激活 | 已在生产环境中使用 |
| 🔜 下一步 | 计划在近期版本中激活 |
| 📋 规划中 | 列入路线图，等待优先级排序 |
| ⏸️ 暂不使用 | 当前产品定位不需要 |

---

## 1. Built-in Tools

### Tool Groups

| Group | Tools | ClawBowl 状态 |
|---|---|---|
| group:fs | read, write, edit, apply_patch | ✅ 已激活 |
| group:runtime | exec, bash, process | ✅ 已激活 |
| group:sessions | sessions_list, sessions_history, sessions_send, sessions_spawn, session_status | 🔜 sessions_spawn |
| group:memory | memory_search, memory_get | ✅ 已激活 |
| group:web | web_search, web_fetch | ✅ 已激活 |
| group:ui | browser, canvas | 🔜 browser |
| group:automation | cron, gateway | 🔜 cron |
| group:messaging | message | ⏸️ 用 iOS App 替代 |
| group:nodes | nodes | ⏸️ 需物理设备 |

### Tool Profiles

| Profile | Scope |
|---|---|
| full | No restriction (default) — 当前使用 |
| coding | group:fs, group:runtime, group:sessions, group:memory, image |
| messaging | group:messaging + session tools |
| minimal | session_status only |

---

### Complete Tool Inventory

#### 1.1 exec ✅
- **What**: Run shell commands in workspace. TTY, background, sandbox/gateway/node targeting, elevated mode, timeouts (default 1800s).
- **Cost**: CPU/memory of command + tokens for output.
- **Setup**: None basic. Docker for sandbox. Paired node for host=node.
- **ClawBowl**: 核心能力，用于执行 Python 脚本、安装工具、处理文件等。

#### 1.2 process ✅
- **What**: Manage background exec sessions (list, poll, log, write, kill, clear, remove). Scoped per agent.
- **Cost**: Minimal.
- **ClawBowl**: 用于管理长时间运行的任务。

#### 1.3 apply_patch
- **What**: Apply structured multi-hunk patches across files. Experimental, OpenAI models only.
- **Cost**: Minimal filesystem I/O.
- **ClawBowl**: 暂不使用（OpenAI models only）。

#### 1.4 read / write / edit ✅
- **What**: Core filesystem tools for reading, writing, editing files.
- **Cost**: Minimal I/O. Tokens scale with file size.
- **ClawBowl**: 核心能力，文件操作基础。

#### 1.5 web_search ✅
- **What**: Search via Brave (default, free tier ~2000 queries/mo) or Perplexity Sonar (AI-synthesized answers with citations). Cached 15min. Count 1-10. Supports country, language, freshness filters.
- **Cost**: Brave free tier or paid. Perplexity per-token.
- **Setup**: BRAVE_API_KEY (已配置) or PERPLEXITY_API_KEY.
- **Perplexity models**: sonar (quick), sonar-pro (complex, default), sonar-reasoning-pro (deep research).
- **ClawBowl**: 使用 Brave 免费额度。Pro 用户可启用 Perplexity。

#### 1.6 web_fetch ✅
- **What**: HTTP GET + Readability extraction (HTML to markdown/text). No JS execution. Fallback: Readability > Firecrawl (anti-bot) > basic HTML. Cached 15min. Max 50K chars. Blocks private hostnames.
- **Cost**: Free basic. Firecrawl uses paid API credits.
- **ClawBowl**: 基础已启用。Premium 可启用 Firecrawl 反爬虫。

#### 1.7 browser 🔜
- **What**: Full browser automation via isolated Chromium profile. Navigate, click, type, drag, select, screenshot, snapshot (AI/ARIA/role/efficient), PDF, upload, download, dialog, console, multi-profile (~100 max), multi-tab. Supports Chrome/Brave/Edge/Chromium. Device emulation, state control (timezone, locale, geo, dark mode, offline, cookies, storage, credentials, headers). Chrome extension relay, Browserless hosted CDP, node browser proxy. Wait power-ups (selector + JS predicate + load state + URL pattern). Tracing and debugging.
- **Cost**: ~200-500MB RAM per profile. Playwright optional but recommended.
- **Setup**: browser.enabled=true (default). Auto-detects Chromium. Optional: Playwright, Browserless, Chrome extension.
- **ClawBowl 计划**: Pro 单标签页，Premium 多标签页。需在 Docker 镜像中安装 Chromium + Playwright。
- **v2026.2.14 新增**: sandbox.browser.binds 支持单独配置浏览器容器挂载。

#### 1.8 canvas 📋
- **What**: Drive node Canvas: present HTML, evaluate JS, snapshot (image), A2UI push/reset. Files in workspace/canvas/. Uses Gateway node.invoke.
- **Cost**: Requires connected node device.
- **Setup**: Paired node (macOS/iOS/Android) with Canvas support.
- **ClawBowl 计划**: 未来可通过 iOS App 内嵌 WebView 实现类似功能。

#### 1.9 nodes ⏸️
- **What**: Discover/target paired nodes. Actions: status, describe, notify, run (macOS system.run), camera_snap, camera_clip, screen_record, location_get, pairing.
- **Cost**: Network I/O. Requires physical devices.
- **ClawBowl**: 暂不使用，需要用户自有设备配对。

#### 1.10 image ✅
- **What**: Analyze images (path or URL) via configured vision model. Independent of main chat model.
- **Cost**: Vision model API call.
- **Setup**: agents.defaults.imageModel configured (已配置 GLM 4.6V Flash).
- **ClawBowl**: 核心能力，用于分析用户上传的图片。
- **v2026.2.14 修复**: workspace-local image paths 现在正确工作。

#### 1.11 message ⏸️
- **What**: Cross-platform messaging across Discord, Google Chat, Slack, Telegram, WhatsApp, Signal, iMessage, MS Teams.
- **Cost**: Network I/O. Per-channel credentials.
- **ClawBowl**: 不使用 OpenClaw 的多平台消息通道，统一通过 iOS App 前端对接用户。

#### 1.12 cron 🔜
- **What**: Gateway cron jobs and wakeups. Actions: add, update, remove, run (immediate), runs (history), status, list, wake (system event + heartbeat).
- **Cost**: Token cost per scheduled agent run.
- **ClawBowl 计划**: Pro 用户可设置定时任务（最多 5 个），Premium 无限制。
- **v2026.2.14 修复**: 修复了中断任务重启循环、missed-job replay 等问题。

#### 1.13 gateway ✅
- **What**: Gateway management. Actions: restart, config.get/schema/patch/apply, update.run.
- **Cost**: Minimal.
- **ClawBowl**: 网关管理，自动使用。

#### 1.14 Session Tools 🔜
- **What**: sessions_list, sessions_history, sessions_send, sessions_spawn, session_status. Multi-session/multi-agent orchestration. List sessions, inspect transcripts, send between sessions, spawn sub-agents with ping-pong.
- **Cost**: Token cost per spawned run.
- **ClawBowl 计划**: sessions_spawn 可实现子任务并行，类似 Manus 的多线程效果。
- **v2026.2.15 新增**: 嵌套子 agent（sub-sub-agents），可配置 spawn 深度。

#### 1.15 agents_list 📋
- **What**: List targetable agent IDs for sessions_spawn.
- **ClawBowl**: 配合 sessions_spawn 使用。

#### 1.16 memory_search / memory_get ✅
- **What**: Semantic vector search over memory Markdown (~400-token chunks, ~700-char snippets). Read specific memory files by path.
- **Cost**: Embedding API (remote) or local GGUF (~0.6GB RAM).
- **Setup**: Auto-detected from API keys or configure local.
- **ClawBowl**: 已启用，使用本地嵌入。Pro 可用 Gemini/OpenAI 远程嵌入。

### Plugin Tools

#### 1.17 llm-task 📋
- **What**: JSON-only LLM step for structured workflow output. Optional JSON Schema validation. For Lobster pipelines.
- **Cost**: LLM API call per invocation.

#### 1.18 lobster 📋
- **What**: Typed workflow runtime with resumable approvals. Deterministic CLI pipelines with JSON piping.
- **Cost**: CPU for subprocesses.

#### 1.19 voice_call ⏸️
- **What**: Voice calls via Twilio.
- **Cost**: Twilio per-minute charges.

---

## 2. Skills System ✅

**What**: AgentSkills-compatible folders with SKILL.md + YAML frontmatter. Inject tool usage guidance into system prompt as compact XML.

**Loading precedence**: workspace/skills/ > ~/.openclaw/skills/ > bundled. Extra dirs via skills.load.extraDirs (lowest).

**Gating**: requires.bins, requires.anyBins, requires.env, requires.config, os filter, always: true.

**Custom skills**: Yes - workspace folder, ClawHub install, managed dir, extra dirs, plugin-shipped.

**ClawHub registry**: Free public at clawhub.ai. Vector search, versioning, tags, stars, comments.

**当前已加载技能**:
- healthcheck — 安全审计和加固
- skill-creator — 创建自定义技能
- weather — 天气查询（无需 API key）

**Token cost**: ~24 tokens/skill. Base overhead ~195 chars when skills present.

---

## 3. Memory System ✅

**Architecture**: Plain Markdown on disk. Model only remembers what is written.

**Files**: MEMORY.md (curated long-term, loaded every private session) + memory/YYYY-MM-DD.md (daily log, today+yesterday).

**Tools**: memory_search (semantic chunks ~400 tokens, snippets ~700 chars) + memory_get (read file by path).

**SQLite backend (default)**: Auto-selects embedding provider (Voyage > Gemini > OpenAI > Local). Hybrid BM25+vector (0.3/0.7 weights). SQLite-vec acceleration. Embedding cache. Batch indexing for large corpus.

**Local embeddings**: node-llama-cpp + GGUF (~0.6GB). Fully offline. No API cost.

**QMD backend (experimental)**: BM25 + vectors + reranking via qmd CLI. Requires Bun.

**Auto memory flush**: ✅ Silent turn before compaction to persist durable notes. 已在 openclaw.json 中显式启用。

**Session memory (experimental)**: Index session transcripts for memory_search. Opt-in flag.

**ClawBowl 当前状态**:
- ✅ 持久会话已启用（通过 user + x-openclaw-session-key）
- ✅ MEMORY.md 已创建种子内容
- ✅ memory/ 目录已创建
- ✅ memory flush 已启用
- ✅ 时区已配置 (Asia/Shanghai)

**Cost**: Free with local embeddings. ~$0.02/1M tokens with OpenAI remote. Gemini free tier available.

---

## 4. Browser Tool (Deep Dive) 🔜

**Core**: Isolated Chromium profile managed by Gateway. Supports Chrome/Brave/Edge/Chromium.

**Capabilities**:
- Navigation: navigate, open, tabs, focus, close, start, stop
- Interaction: act (click/type/press/hover/drag/select/fill/resize/wait/evaluate)
- Inspection: snapshot (AI/ARIA/role/efficient), screenshot (full/element), pdf, console
- File I/O: upload, download, dialog handling
- State: timezone, locale, geolocation, dark/light, device emulation, offline, cookies, storage, credentials, headers
- Profiles: openclaw (isolated), chrome (extension relay), custom (remote CDP, Browserless)
- Debugging: trace start/stop, highlight, errors, requests, console

**Snapshots**: AI (numeric refs), Role (e12 refs with --interactive/--compact/--depth/--selector/--frame), ARIA (no refs), Efficient (compact preset).

**Advanced**: Multi-profile (~100), node browser proxy, Browserless hosted CDP, Chrome extension relay, sandbox awareness, Control API (loopback HTTP), wait power-ups, device presets.

**Cost**: ~200-500MB RAM per profile. Free local. Browserless is paid subscription.

**ClawBowl 激活计划**: 需在 Docker 镜像中安装 Chromium + Playwright → Pro 用户启用。

---

## 5. Cron / Automation 🔜

**What**: Gateway-managed cron jobs for recurring agent tasks.

**Actions**: add, update, remove, run (immediate), runs (history), status, list, wake (system event + heartbeat).

**Related files**: HEARTBEAT.md (heartbeat guidance), BOOT.md (startup checklist).

**Gateway tool**: restart, config management (get/schema/patch/apply), update.run.

**ClawBowl 激活计划**: Agent 可自主创建定时任务（检查邮件、天气预报、定期汇总等）。Pro 限 5 个，Premium 无限。

**Cost**: Node.js Gateway process. Token cost per scheduled run. Free tier.

---

## 6. Web Tools ✅

**web_search**: Brave (default, free ~2K queries/mo) or Perplexity Sonar (3 model tiers: sonar, sonar-pro, sonar-reasoning-pro). Params: query, count 1-10, country, search_lang, ui_lang, freshness. Cached 15min.

**web_fetch**: HTTP GET + Readability. No JS. Firecrawl fallback (anti-bot, paid). Max 50K chars. Cached 15min. Blocks private hosts.

**Firecrawl**: Hosted extraction, bot circumvention (proxy: auto). Cache default 2 days. Paid credits.

**ClawBowl 当前**: Brave 免费搜索已启用。Firecrawl 可在 Premium 启用。

---

## 7. Canvas 📋

**What**: Display surface on paired nodes for presenting HTML, evaluating JS, rendering UI.

**Actions**: present, hide, navigate, eval, snapshot (image), a2ui_push (v0.8), a2ui_reset.

**Files**: workspace/canvas/ (e.g., canvas/index.html).

**Requires**: Paired node device with Canvas support + Gateway running.

**ClawBowl**: 未来可通过 iOS App 内嵌 WebView 替代实现，不依赖 node 配对。

---

## 8. Plugin System 📋

**What**: TypeScript modules loaded at runtime (jiti), in-process with Gateway.

**Can register**: Agent tools, CLI commands, Gateway RPC, HTTP handlers, background services, skills, auto-reply commands, channel plugins, provider auth, hooks.

**Precedence**: Config paths > workspace extensions > global extensions > bundled (disabled by default).

**Official plugins (14+)**:
| Plugin | Package | Type | ClawBowl |
|---|---|---|---|
| Voice Call | @openclaw/voice-call | Telephony | ⏸️ |
| Memory Core | Bundled | Memory | ✅ 已启用 |
| Memory LanceDB | Bundled | Memory | 📋 备选 |
| MS Teams | @openclaw/msteams | Channel | ⏸️ |
| Matrix | @openclaw/matrix | Channel | ⏸️ |
| Nostr | @openclaw/nostr | Channel | ⏸️ |
| Zalo | @openclaw/zalo | Channel | ⏸️ |
| Zalo Personal | @openclaw/zalouser | Channel | ⏸️ |
| LLM Task | Bundled | Workflow | 📋 |
| Lobster | Bundled | Workflow | 📋 |
| Google Antigravity OAuth | Bundled | Auth | 📋 |
| Gemini CLI OAuth | Bundled | Auth | 📋 |
| Qwen OAuth | Bundled | Auth | ⏸️ |
| Copilot Proxy | Bundled | Auth | ⏸️ |

**Slots**: Exclusive categories (memory: memory-core | memory-lancedb | none).

---

## 9. Suitability Matrix

### Free Tier (no paid external services)

| Capability | Notes | ClawBowl |
|---|---|---|
| exec / process / bash | Core shell | ✅ |
| read / write / edit / apply_patch | Core filesystem | ✅ |
| browser (local) | Local Chromium, Playwright optional | 🔜 Pro |
| canvas / nodes | Own hardware required | ⏸️ |
| cron / gateway | Gateway-managed scheduling | 🔜 Pro |
| session tools / agents_list | Multi-session/agent | 🔜 |
| message | Channel credentials needed | ⏸️ |
| memory (local) | GGUF embeddings (~0.6GB) | ✅ |
| web_fetch (basic) | No API key | ✅ |
| Skills / ClawHub | Core + free registry | ✅ |
| Plugin system / Lobster | Bundled free | 📋 |

### Requires API Keys (free tiers may exist)

| Capability | Provider | Free Tier? | ClawBowl |
|---|---|---|---|
| web_search (Brave) | Brave Search | Yes (~2K queries/mo) | ✅ 已配置 |
| memory_search (remote) | OpenAI / Gemini / Voyage | Gemini has free tier | 📋 Pro |
| image analysis | Vision model | Depends | ✅ GLM 4.6V |
| Main agent LLM | Various | No | ✅ DeepSeek V3.2 |

### Premium (paid services)

| Capability | Provider | Cost Model | ClawBowl |
|---|---|---|---|
| web_search (Perplexity) | Perplexity / OpenRouter | Per-token | 📋 Premium |
| web_fetch (Firecrawl) | Firecrawl | Per-scrape credits | 📋 Premium |
| browser (Browserless) | Browserless | Subscription | ⏸️ |
| voice_call | Twilio | Per-minute | ⏸️ |
| llm-task | LLM provider | Per-token | 📋 |
| Remote batch embeddings | OpenAI Batch API | Per-token (discounted) | 📋 |

### Infrastructure Requirements

| Requirement | For | ClawBowl |
|---|---|---|
| Node.js 22+ | Gateway runtime | ✅ 已在容器中 |
| Chromium browser | Browser tool (auto-detected) | 🔜 需安装 |
| Playwright | Advanced browser features | 🔜 需安装 |
| Docker | Sandboxing | ✅ |
| macOS/iOS/Android device | Nodes, Canvas, camera/screen | ⏸️ |
| Bun | QMD memory backend | ⏸️ |
| Lobster CLI | Workflow runtime | 📋 |

---

## 10. Recent Version Highlights

### v2026.2.14 (2026-02-15) — 当前版本
- Telegram poll 发送
- Discord exec approval 可定向 channel
- Sandbox browser bind mounts 配置
- 大量安全加固（SSRF、webhook 签名、PATH、CSRF、路径穿越）
- Cron 调度修复
- workspace-local image paths 修复
- 嵌套子 agent（v2026.2.15 预览）

### v2026.2.13 (2026-02-14)
- Hugging Face Inference provider 支持
- GLM-5 模型支持
- Discord presence 状态配置
- Discord voice messages
- 会话 transcript 归档（/new /reset 时清理旧文件）
- Heartbeat 调度稳定性改进

### v2026.2.6 及更早 (2026-01-02)
- Unbrowse 浏览器自动化（visual element detection）
- xAI (Grok) provider 支持
- Anthropic Opus 4.6 + OpenAI Codex 模型支持
- Native Voyage AI 支持
- Token usage dashboard
- 语音消息转写
- Calendar 集成
- Workflow recording/replay
- Skill marketplace
- 40% 启动时间优化
- 12 语言支持
- Location-aware reminders

---

## Summary

| Category | Count |
|---|---|
| Core tools | 16+ |
| Plugin tools | 3+ (plus community) |
| Messaging channels | 8+ built-in + 4+ plugin |
| Memory backends | 2 (SQLite, QMD) |
| Embedding providers | 5 (Voyage, Gemini, OpenAI, Local GGUF, Batch) |
| Search providers | 2 (Brave, Perplexity x3 models) |
| Browser profiles | ~100 max |
| Tool profiles | 4 |
| Official plugins | 14+ |
| Skill sources | 4 (workspace, managed, bundled, ClawHub) |
| LLM providers | 10+ (DeepSeek, Anthropic, OpenAI, Gemini, Ollama, HuggingFace, xAI, MiniMax, vLLM, Codex) |

### ClawBowl 激活进度

| 状态 | 数量 | 工具 |
|---|---|---|
| ✅ 已激活 | 10 | exec, process, read/write/edit, image, web_search, web_fetch, memory_search/get, gateway, skills |
| 🔜 下一步 | 4 | browser, cron, sessions_spawn, heartbeat |
| 📋 规划中 | 5 | canvas(WebView), lobster, llm-task, agents_list, remote embeddings |
| ⏸️ 暂不使用 | 5 | message(8平台), nodes, voice_call, apply_patch, QMD |
