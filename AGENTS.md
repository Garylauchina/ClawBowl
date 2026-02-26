# AGENTS.md

## Cursor Cloud specific instructions

### Project overview

Tarz (codename ClawBowl) is a hosted AI Agent platform. The backend is a Python FastAPI orchestrator that manages per-user OpenClaw Docker containers. The iOS client (SwiftUI) is not buildable in this environment.

### Running the backend

```bash
cd /workspace/backend
uvicorn app.main:app --host 127.0.0.1 --port 8000 --reload
```

The `.env` file must exist in `/workspace/backend/` (copy from `.env.example` if missing). SQLite DB is auto-created on first startup. See `DESIGN.md` for full architecture details.

### Linting

```bash
ruff check backend/
```

There are 3 pre-existing unused-import warnings (F401) in `alert_monitor.py` and `apns_service.py`. These are known and not blocking.

### Testing

No automated test suite exists in the repository. Validate backend functionality via API calls (see `DESIGN.md` Appendix B for endpoint list) or the interactive docs at `http://127.0.0.1:8000/docs`.

### Key gotchas

- The backend requires Docker to be running (`dockerd`) for container lifecycle operations (warmup, instance creation). Without Docker, auth endpoints still work but instance/chat endpoints will fail.
- The `.env` defaults use a placeholder JWT secret (`change-me-to-a-strong-random-secret`). This is fine for local dev but not production.
- `pip install` goes to `~/.local/` in this environment. Ensure `$HOME/.local/bin` is on `PATH` for `uvicorn`, `alembic`, and `ruff` commands.
- The iOS app (`ClawBowl/`) is a Swift/SwiftUI project requiring Xcode on macOS — not runnable in this Linux environment.
