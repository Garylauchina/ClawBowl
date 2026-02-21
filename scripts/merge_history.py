"""One-time merge: chat_logs DB → container JSONL.

Reads all user/assistant messages from both sources, deduplicates,
and appends DB-only messages into the primary session JSONL file.

Run once with: sudo python3 scripts/merge_history.py
"""

import json
import sqlite3
import pathlib
from datetime import datetime, timezone

DATA_PATH = pathlib.Path(
    "/var/lib/clawbowl/f8a44871-10c2-4707-b0bd-8efaac516316"
)
SESSIONS_DIR = DATA_PATH / "config" / "agents" / "main" / "sessions"
DB_PATH = pathlib.Path("/home/ubuntu/ClawBowl/backend/clawbowl.db")
PRIMARY_SESSION_ID = "53fa937b-41bb-4569-b570-536e55cefed8"

SYSTEM_PATTERNS = ("cron:", "hook:", "tui-test", "test-busy", "agent:main:main")


def load_jsonl_messages() -> list[dict]:
    """Load all user/assistant messages from all non-system JSONL files."""
    sj_path = SESSIONS_DIR / "sessions.json"
    sessions_map = json.loads(sj_path.read_text())

    user_session_ids = set()
    for key, val in sessions_map.items():
        if any(p in key for p in SYSTEM_PATTERNS):
            continue
        sid = val.get("sessionId")
        if sid:
            user_session_ids.add(sid)

    messages = []
    for jf in SESSIONS_DIR.glob("*.jsonl"):
        if jf.stem not in user_session_ids:
            continue
        for line in open(jf):
            try:
                entry = json.loads(line)
            except json.JSONDecodeError:
                continue
            if entry.get("type") != "message":
                continue
            msg = entry.get("message", {})
            role = msg.get("role")
            if role not in ("user", "assistant"):
                continue
            content = msg.get("content", "")
            if isinstance(content, list):
                content = "".join(
                    p.get("text", "") for p in content if p.get("type") == "text"
                )
            if not content or not isinstance(content, str):
                continue
            if content.startswith("[Chat messages since"):
                continue
            if content.startswith("Continue where you left off"):
                continue

            messages.append({
                "timestamp": entry.get("timestamp", ""),
                "role": role,
                "content": content,
            })

    messages.sort(key=lambda m: m["timestamp"])
    print(f"[JSONL] Loaded {len(messages)} user/assistant messages")
    return messages


def load_db_messages() -> list[dict]:
    """Load all user/assistant messages from chat_logs DB."""
    conn = sqlite3.connect(str(DB_PATH))
    cur = conn.execute(
        "SELECT created_at, role, content FROM chat_logs "
        "WHERE role IN ('user', 'assistant') AND content != '' "
        "ORDER BY created_at"
    )
    messages = []
    for row in cur:
        created_at, role, content = row
        if not content or not content.strip():
            continue
        if content.startswith("[Chat messages since"):
            continue
        ts = created_at.replace(" ", "T") + "Z"
        messages.append({
            "timestamp": ts,
            "role": role,
            "content": content,
        })
    conn.close()
    print(f"[DB] Loaded {len(messages)} user/assistant messages")
    return messages


def normalize_ts(ts_str: str) -> float:
    """Parse ISO timestamp to epoch seconds for comparison."""
    ts = ts_str.rstrip("Z").split("+")[0]
    for fmt in ("%Y-%m-%dT%H:%M:%S.%f", "%Y-%m-%dT%H:%M:%S"):
        try:
            dt = datetime.strptime(ts, fmt).replace(tzinfo=timezone.utc)
            return dt.timestamp()
        except ValueError:
            continue
    return 0.0


def find_db_only(db_msgs: list[dict], jsonl_msgs: list[dict]) -> list[dict]:
    """Find messages in DB that don't exist in JSONL (by role+content+time±5s)."""
    jsonl_index = set()
    for m in jsonl_msgs:
        key = (m["role"], m["content"].strip()[:200])
        jsonl_index.add(key)

    jsonl_ts_map: dict[tuple, list[float]] = {}
    for m in jsonl_msgs:
        key = (m["role"], m["content"].strip()[:200])
        jsonl_ts_map.setdefault(key, []).append(normalize_ts(m["timestamp"]))

    db_only = []
    for m in db_msgs:
        key = (m["role"], m["content"].strip()[:200])
        if key not in jsonl_index:
            db_only.append(m)
            continue
        db_ts = normalize_ts(m["timestamp"])
        timestamps = jsonl_ts_map.get(key, [])
        if not any(abs(db_ts - jts) < 5.0 for jts in timestamps):
            db_only.append(m)

    return db_only


def append_to_primary_session(messages: list[dict]):
    """Append messages to the primary session JSONL file."""
    primary_path = SESSIONS_DIR / f"{PRIMARY_SESSION_ID}.jsonl"
    if not primary_path.exists():
        print(f"[ERROR] Primary session file not found: {primary_path}")
        return

    with open(primary_path, "a") as f:
        for m in messages:
            entry = {
                "type": "message",
                "id": f"merged-{hash(m['content'][:50] + m['timestamp']) & 0xFFFFFFFF:08x}",
                "parentId": None,
                "timestamp": m["timestamp"],
                "message": {
                    "role": m["role"],
                    "content": m["content"],
                },
            }
            f.write(json.dumps(entry, ensure_ascii=False) + "\n")

    print(f"[MERGE] Appended {len(messages)} messages to {primary_path.name}")


def main():
    print("=== Chat History Merge: chat_logs DB → Container JSONL ===\n")

    jsonl_msgs = load_jsonl_messages()
    db_msgs = load_db_messages()

    if not db_msgs:
        print("\n[DONE] No DB messages to merge.")
        return

    db_only = find_db_only(db_msgs, jsonl_msgs)
    print(f"\n[DIFF] DB-only messages (not in JSONL): {len(db_only)}")

    if not db_only:
        print("[DONE] All DB messages already exist in JSONL. Nothing to merge.")
        return

    print("\nSample DB-only messages:")
    for m in db_only[:5]:
        print(f"  {m['timestamp']} [{m['role']}] {m['content'][:60]}")
    if len(db_only) > 5:
        print(f"  ... and {len(db_only) - 5} more")

    append_to_primary_session(db_only)
    print("\n[DONE] Merge complete.")


if __name__ == "__main__":
    main()
