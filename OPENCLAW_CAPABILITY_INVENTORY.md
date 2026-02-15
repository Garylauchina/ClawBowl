# OpenClaw Capability Inventory

> Source: docs.openclaw.ai (fetched 2026-02-15)

## 1. Built-in Tools

### Tool Groups

| Group | Tools |
|---|---|
| group:openclaw | All built-in tools (excludes plugin tools) |
| group:fs | read, write, edit, apply_patch |
| group:runtime | exec, bash, process |
| group:sessions | sessions_list, sessions_history, sessions_send, sessions_spawn, session_status |
| group:memory | memory_search, memory_get |
| group:web | web_search, web_fetch |
| group:ui | browser, canvas |
| group:automation | cron, gateway |
| group:messaging | message |
| group:nodes | nodes |

### Tool Profiles

| Profile | Scope |
|---|---|
| full | No restriction (default) |
| coding | group:fs, group:runtime, group:sessions, group:memory, image |
| messaging | group:messaging + session tools |
| minimal | session_status only |

---

### Complete Tool Inventory

#### 1.1 exec
- **What**: Run shell commands in workspace. TTY, background, sandbox/gateway/node targeting, elevated mode, timeouts (default 1800s).
- **Cost**: CPU/memory of command + tokens for output.
- **Setup**: None basic. Docker for sandbox. Paired node for host=node.
- **Tier**: Free.

#### 1.2 process
- **What**: Manage background exec sessions (list, poll, log, write, kill, clear, remove). Scoped per agent.
- **Cost**: Minimal.
- **Setup**: None.
- **Tier**: Free.

#### 1.3 apply_patch
- **What**: Apply structured multi-hunk patches across files. Experimental, OpenAI models only.
- **Cost**: Minimal filesystem I/O.
- **Setup**: Enable via tools.exec.applyPatch.enabled.
- **Tier**: Free. Experimental.

#### 1.4 read / write / edit
- **What**: Core filesystem tools for reading, writing, editing files.
- **Cost**: Minimal I/O. Tokens scale with file size.
- **Setup**: None.
- **Tier**: Free.

#### 1.5 web_search
- **What**: Search via Brave (default, free tier ~2000 queries/mo) or Perplexity Sonar (AI-synthesized answers with citations). Cached 15min. Count 1-10. Supports country, language, freshness filters.
- **Cost**: Brave free tier or paid. Perplexity per-token.
- **Setup**: BRAVE_API_KEY or PERPLEXITY_API_KEY / OPENROUTER_API_KEY.
- **Perplexity models**: sonar (quick), sonar-pro (complex, default), sonar-reasoning-pro (deep research).
- **Tier**: Free with Brave. Premium with Perplexity.

#### 1.6 web_fetch
- **What**: HTTP GET + Readability extraction (HTML to markdown/text). No JS execution. Fallback: Readability > Firecrawl (anti-bot) > basic HTML. Cached 15min. Max 50K chars. Blocks private hostnames.
- **Cost**: Free basic. Firecrawl uses paid API credits.
- **Setup**: None basic. FIRECRAWL_API_KEY for fallback.
- **Tier**: Free basic. Premium for Firecrawl.

#### 1.7 browser
- **What**: Full browser automation via isolated Chromium profile. Navigate, click, type, drag, select, screenshot, snapshot (AI/ARIA/role/efficient), PDF, upload, download, dialog, console, multi-profile (~100 max), multi-tab. Supports Chrome/Brave/Edge/Chromium. Device emulation, state control (timezone, locale, geo, dark mode, offline, cookies, storage, credentials, headers). Chrome extension relay, Browserless hosted CDP, node browser proxy. Wait power-ups (selector + JS predicate + load state + URL pattern). Tracing and debugging.
- **Cost**: ~200-500MB RAM per profile. Playwright optional but recommended.
- **Setup**: browser.enabled=true (default). Auto-detects Chromium. Optional: Playwright, Browserless, Chrome extension.
- **Tier**: Free local. Premium for Browserless.

#### 1.8 canvas
- **What**: Drive node Canvas: present HTML, evaluate JS, snapshot (image), A2UI push/reset. Files in workspace/canvas/. Uses Gateway node.invoke.
- **Cost**: Requires connected node device.
- **Setup**: Paired node (macOS/iOS/Android) with Canvas support.
- **Tier**: Free with own hardware. Unavailable without node.

#### 1.9 nodes
- **What**: Discover/target paired nodes. Actions: status, describe, notify, run (macOS system.run), camera_snap, camera_clip, screen_record, location_get, pairing (pending/approve/reject). Videos return mp4. Images return image blocks.
- **Cost**: Network I/O.
- **Setup**: Paired node device.
- **Tier**: Free self-hosted. Requires physical devices.

#### 1.10 image
- **What**: Analyze images (path or URL) via configured vision model. Independent of main chat model.
- **Cost**: Vision model API call.
- **Setup**: agents.defaults.imageModel configured.
- **Tier**: Requires vision model API key.

#### 1.11 message
- **What**: Cross-platform messaging across Discord, Google Chat, Slack, Telegram, WhatsApp, Signal, iMessage, MS Teams. Actions: send, read, edit, delete, react, search, thread-create/reply/list, pin/unpin/list-pins, poll (WhatsApp/Discord/Teams), channel-info/list, member-info, role-add/remove/info, emoji-list/upload, sticker/sticker-upload, voice-status, event-list/create, timeout/kick/ban, permissions. MS Teams supports Adaptive Cards.
- **Cost**: Network I/O. Per-channel credentials.
- **Setup**: Bot tokens, QR pairing (WhatsApp), etc.
- **Tier**: Free. Credentials needed per channel.

#### 1.12 cron
- **What**: Gateway cron jobs and wakeups. Actions: add, update, remove, run (immediate), runs (history), status, list, wake (system event + heartbeat).
- **Cost**: Token cost per scheduled agent run.
- **Setup**: Gateway running continuously.
- **Tier**: Free. Token cost per execution.

#### 1.13 gateway
- **What**: Gateway management. Actions: restart (SIGUSR1), config.get/schema/patch/apply, update.run.
- **Cost**: Minimal.
- **Setup**: commands.restart: true for restart.
- **Tier**: Free.

#### 1.14 Session Tools
- **What**: sessions_list, sessions_history, sessions_send, sessions_spawn, session_status. Multi-session/multi-agent orchestration. List sessions, inspect transcripts, send between sessions, spawn sub-agents with ping-pong.
- **Cost**: Token cost per spawned run.
- **Setup**: Multi-agent requires agents.list[] config.
- **Tier**: Free.

#### 1.15 agents_list
- **What**: List targetable agent IDs for sessions_spawn. Respects per-agent allowlists.
- **Cost**: Minimal.
- **Tier**: Free.

#### 1.16 memory_search / memory_get
- **What**: Semantic vector search over memory Markdown (~400-token chunks, ~700-char snippets). Read specific memory files by path.
- **Cost**: Embedding API (remote) or local GGUF (~0.6GB RAM).
- **Setup**: Auto-detected from API keys or configure local.
- **Tier**: Free with local embeddings.

### Plugin Tools

#### 1.17 llm-task
- **What**: JSON-only LLM step for structured workflow output. Optional JSON Schema validation. For Lobster pipelines.
- **Cost**: LLM API call per invocation.
- **Setup**: Enable plugin + allowlist tool.
- **Tier**: Premium (LLM API cost).

#### 1.18 lobster
- **What**: Typed workflow runtime with resumable approvals. Deterministic CLI pipelines with JSON piping. .lobster YAML workflow files. Approval gates with resume tokens.
- **Cost**: CPU for subprocesses.
- **Setup**: Install Lobster CLI. Enable plugin.
- **Tier**: Free (local subprocess).

#### 1.19 voice_call
- **What**: Voice calls via Twilio (or log fallback for dev).
- **Cost**: Twilio per-minute charges.
- **Setup**: @openclaw/voice-call plugin + Twilio credentials.
- **Tier**: Premium.

---

## 2. Skills System

**What**: AgentSkills-compatible folders with SKILL.md + YAML frontmatter. Inject tool usage guidance into system prompt as compact XML.

**Loading precedence**: workspace/skills/ > ~/.openclaw/skills/ > bundled. Extra dirs via skills.load.extraDirs (lowest).

**Gating**: requires.bins, requires.anyBins, requires.env, requires.config, os filter, always: true.

**Custom skills**: Yes - workspace folder, ClawHub install, managed dir, extra dirs, plugin-shipped.

**ClawHub registry**: Free public at clawhub.ai. Vector search, versioning, tags, stars, comments. CLI: search/install/update/sync/publish. GitHub account (1+ week old) to publish. Moderation: auto-hide after 3 reports.

**Token cost**: ~24 tokens/skill. Base overhead ~195 chars when skills present.

**Tier**: Free. Core functionality.

---

## 3. Memory System

**Architecture**: Plain Markdown on disk. Model only remembers what is written.

**Files**: MEMORY.md (curated long-term, loaded every private session) + memory/YYYY-MM-DD.md (daily log, today+yesterday).

**Tools**: memory_search (semantic chunks ~400 tokens, snippets ~700 chars) + memory_get (read file by path).

**SQLite backend (default)**: Auto-selects embedding provider (Voyage > Gemini > OpenAI > Local). Hybrid BM25+vector (0.3/0.7 weights). SQLite-vec acceleration. Embedding cache. Batch indexing for large corpus.

**Local embeddings**: node-llama-cpp + GGUF (~0.6GB). Fully offline. No API cost.

**QMD backend (experimental)**: BM25 + vectors + reranking via qmd CLI. Requires Bun. Session transcript indexing opt-in. Periodic refresh (default 5min).

**Auto memory flush**: Silent turn before compaction to persist durable notes.

**Session memory (experimental)**: Index session transcripts for memory_search. Opt-in flag.

**Cost**: Free with local embeddings. ~$0.02/1M tokens with OpenAI remote. Gemini free tier available.

---

## 4. Browser Tool (Deep Dive)

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

---

## 5. Cron / Automation

**What**: Gateway-managed cron jobs for recurring agent tasks.

**Actions**: add, update, remove, run (immediate), runs (history), status, list, wake (system event + heartbeat).

**Related files**: HEARTBEAT.md (heartbeat guidance), BOOT.md (startup checklist).

**Gateway tool**: restart, config management (get/schema/patch/apply), update.run.

**Cost**: Node.js Gateway process. Token cost per scheduled run. Free tier.

---

## 6. Web Tools

**web_search**: Brave (default, free ~2K queries/mo) or Perplexity Sonar (3 model tiers: sonar, sonar-pro, sonar-reasoning-pro). Params: query, count 1-10, country, search_lang, ui_lang, freshness. Cached 15min.

**web_fetch**: HTTP GET + Readability. No JS. Firecrawl fallback (anti-bot, paid). Max 50K chars. Cached 15min. Blocks private hosts.

**Firecrawl**: Hosted extraction, bot circumvention (proxy: auto). Cache default 2 days. Paid credits.

---

## 7. Canvas

**What**: Display surface on paired nodes for presenting HTML, evaluating JS, rendering UI.

**Actions**: present, hide, navigate, eval, snapshot (image), a2ui_push (v0.8), a2ui_reset.

**Files**: workspace/canvas/ (e.g., canvas/index.html).

**Requires**: Paired node device with Canvas support + Gateway running.

**Cost**: Free with own hardware. Unavailable without physical node.

---

## 8. Plugin System

**What**: TypeScript modules loaded at runtime (jiti), in-process with Gateway.

**Can register**: Agent tools, CLI commands, Gateway RPC, HTTP handlers, background services, skills, auto-reply commands, channel plugins, provider auth, hooks.

**Precedence**: Config paths > workspace extensions > global extensions > bundled (disabled by default).

**Official plugins (14+)**:
| Plugin | Package | Type |
|---|---|---|
| Voice Call | @openclaw/voice-call | Telephony |
| Memory Core | Bundled | Memory |
| Memory LanceDB | Bundled | Memory |
| MS Teams | @openclaw/msteams | Channel |
| Matrix | @openclaw/matrix | Channel |
| Nostr | @openclaw/nostr | Channel |
| Zalo | @openclaw/zalo | Channel |
| Zalo Personal | @openclaw/zalouser | Channel |
| LLM Task | Bundled | Workflow |
| Lobster | Bundled | Workflow |
| Google Antigravity OAuth | Bundled | Auth |
| Gemini CLI OAuth | Bundled | Auth |
| Qwen OAuth | Bundled | Auth |
| Copilot Proxy | Bundled | Auth |

**Slots**: Exclusive categories (memory: memory-core | memory-lancedb | none).

**Install**: npm, local path, tarball, zip, link (dev). --ignore-scripts for npm.

**Custom**: Export object or function. Register channels, providers, RPC, CLI, commands, services.

---

## 9. Suitability Matrix

### Free Tier (no paid external services)

| Capability | Notes |
|---|---|
| exec / process / bash | Core shell |
| read / write / edit / apply_patch | Core filesystem |
| browser (local) | Local Chromium, Playwright optional |
| canvas / nodes | Own hardware required |
| cron / gateway | Gateway-managed scheduling |
| session tools / agents_list | Multi-session/agent |
| message | Channel credentials needed (no per-message cost) |
| memory (local) | GGUF embeddings (~0.6GB) |
| web_fetch (basic) | No API key |
| Skills / ClawHub | Core + free registry |
| Plugin system / Lobster | Bundled free |

### Requires API Keys (free tiers may exist)

| Capability | Provider | Free Tier? |
|---|---|---|
| web_search (Brave) | Brave Search | Yes (~2K queries/mo) |
| memory_search (remote) | OpenAI / Gemini / Voyage | Gemini has free tier |
| image analysis | Vision model | Depends on provider |
| Main agent LLM | Anthropic / OpenAI / etc. | No (always required) |

### Premium (paid services)

| Capability | Provider | Cost Model |
|---|---|---|
| web_search (Perplexity) | Perplexity / OpenRouter | Per-token |
| web_fetch (Firecrawl) | Firecrawl | Per-scrape credits |
| browser (Browserless) | Browserless | Subscription |
| voice_call | Twilio | Per-minute |
| llm-task | LLM provider | Per-token |
| Remote batch embeddings | OpenAI Batch API | Per-token (discounted) |

### Infrastructure Requirements

| Requirement | For |
|---|---|
| Node.js 22+ | Gateway runtime |
| Chromium browser | Browser tool (auto-detected) |
| Playwright | Advanced browser features |
| Docker | Sandboxing |
| macOS/iOS/Android device | Nodes, Canvas, camera/screen |
| Bun | QMD memory backend |
| Lobster CLI | Workflow runtime |

---

## Summary

| Category | Count |
|---|---|
| Core tools | 16+ |
| Plugin tools | 3+ (plus community) |
| Messaging channels | 8+ built-in + 4+ plugin |
| Memory backends | 2 (SQLite, QMD) |
| Embedding providers | 5 |
| Search providers | 2 (Brave, Perplexity x3 models) |
| Browser profiles | ~100 max |
| Tool profiles | 4 |
| Official plugins | 14+ |
| Skill sources | 4 (workspace, managed, bundled, ClawHub) |
