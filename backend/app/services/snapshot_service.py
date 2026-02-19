"""Workspace snapshot service — tar.zst + manifest.json.

Phase 1 basic implementation:
- Create compressed snapshots of a user's workspace directory
- Sequential snap IDs (000001, 000002, ...)
- SHA-256 integrity verification
- Retention policy with automatic cleanup
- Restore from any snapshot
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from app.models import OpenClawInstance

logger = logging.getLogger("clawbowl.snapshot")


def _snapshots_dir(instance: OpenClawInstance) -> Path:
    return Path(instance.data_path) / "snapshots"


def _workspace_dir(instance: OpenClawInstance) -> Path:
    return Path(instance.data_path) / "workspace"


def _next_snap_id(snapshots_dir: Path) -> str:
    """Return the next sequential snap ID like '000001'."""
    existing = sorted(
        (d.name for d in snapshots_dir.iterdir() if d.is_dir() and d.name.isdigit()),
    )
    if not existing:
        return "000001"
    return f"{int(existing[-1]) + 1:06d}"


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 16), b""):
            h.update(chunk)
    return f"sha256:{h.hexdigest()}"


def _create_snapshot_sync(
    instance: OpenClawInstance,
    source: str,
) -> dict:
    """Blocking snapshot creation — run via asyncio.to_thread."""
    snap_dir = _snapshots_dir(instance)
    snap_dir.mkdir(parents=True, exist_ok=True)
    ws_dir = _workspace_dir(instance)

    if not ws_dir.is_dir():
        raise FileNotFoundError(f"Workspace not found: {ws_dir}")

    snap_id = _next_snap_id(snap_dir)
    dest = snap_dir / snap_id
    dest.mkdir(parents=True, exist_ok=True)

    archive_path = dest / "files.tar.zst"

    # tar -C workspace -cf - . | zstd -3 -o archive
    proc = subprocess.run(
        ["tar", "-C", str(ws_dir), "-cf", "-", "."],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"tar failed: {proc.stderr.decode()[:200]}")

    zstd_proc = subprocess.run(
        ["zstd", "-3", "--no-progress", "-o", str(archive_path)],
        input=proc.stdout,
        capture_output=True,
    )
    if zstd_proc.returncode != 0:
        raise RuntimeError(f"zstd failed: {zstd_proc.stderr.decode()[:200]}")

    files_hash = _sha256_file(archive_path)
    files_size = archive_path.stat().st_size

    # Determine previous snap_id
    all_snaps = sorted(
        (d.name for d in snap_dir.iterdir() if d.is_dir() and d.name.isdigit()),
    )
    prev_idx = all_snaps.index(snap_id)
    prev_snap_id = all_snaps[prev_idx - 1] if prev_idx > 0 else None

    manifest = {
        "rid": instance.user_id,
        "snap_id": snap_id,
        "created_at": datetime.now(timezone.utc).isoformat(),
        "source": source,
        "files_hash": files_hash,
        "files_size_bytes": files_size,
        "prev_snap_id": prev_snap_id,
    }

    manifest_path = dest / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")

    logger.info(
        "Snapshot %s created: source=%s, size=%d bytes, hash=%s",
        snap_id, source, files_size, files_hash[:30],
    )
    return manifest


async def create_snapshot(
    instance: OpenClawInstance,
    source: str = "manual",
) -> dict:
    """Create a snapshot asynchronously. Returns the manifest dict."""
    return await asyncio.to_thread(_create_snapshot_sync, instance, source)


def _list_snapshots_sync(instance: OpenClawInstance) -> list[dict]:
    snap_dir = _snapshots_dir(instance)
    if not snap_dir.is_dir():
        return []
    results = []
    for d in sorted(snap_dir.iterdir()):
        if not d.is_dir() or not d.name.isdigit():
            continue
        manifest_path = d / "manifest.json"
        if manifest_path.exists():
            try:
                results.append(json.loads(manifest_path.read_text(encoding="utf-8")))
            except (json.JSONDecodeError, OSError):
                pass
    return results


async def list_snapshots(instance: OpenClawInstance) -> list[dict]:
    return await asyncio.to_thread(_list_snapshots_sync, instance)


def _restore_snapshot_sync(instance: OpenClawInstance, snap_id: str) -> None:
    snap_dir = _snapshots_dir(instance)
    archive_path = snap_dir / snap_id / "files.tar.zst"
    if not archive_path.exists():
        raise FileNotFoundError(f"Snapshot {snap_id} not found")

    ws_dir = _workspace_dir(instance)

    # Verify integrity
    manifest_path = snap_dir / snap_id / "manifest.json"
    if manifest_path.exists():
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        expected_hash = manifest.get("files_hash", "")
        actual_hash = _sha256_file(archive_path)
        if expected_hash and actual_hash != expected_hash:
            raise ValueError(
                f"Integrity check failed: expected {expected_hash}, got {actual_hash}"
            )

    # Decompress + extract (overwrite existing files)
    proc = subprocess.run(
        ["zstd", "-d", "--stdout", str(archive_path)],
        capture_output=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(f"zstd decompress failed: {proc.stderr.decode()[:200]}")

    tar_proc = subprocess.run(
        ["tar", "-C", str(ws_dir), "-xf", "-"],
        input=proc.stdout,
        capture_output=True,
    )
    if tar_proc.returncode != 0:
        raise RuntimeError(f"tar extract failed: {tar_proc.stderr.decode()[:200]}")

    logger.info("Snapshot %s restored to %s", snap_id, ws_dir)


async def restore_snapshot(instance: OpenClawInstance, snap_id: str) -> None:
    return await asyncio.to_thread(_restore_snapshot_sync, instance, snap_id)


def _cleanup_snapshots_sync(instance: OpenClawInstance, keep_count: int = 3) -> int:
    """Remove oldest snapshots beyond *keep_count*. Returns number removed."""
    snap_dir = _snapshots_dir(instance)
    if not snap_dir.is_dir():
        return 0
    all_snaps = sorted(
        (d for d in snap_dir.iterdir() if d.is_dir() and d.name.isdigit()),
        key=lambda d: d.name,
    )
    to_remove = all_snaps[:-keep_count] if len(all_snaps) > keep_count else []
    removed = 0
    for d in to_remove:
        try:
            import shutil
            shutil.rmtree(d)
            removed += 1
            logger.info("Cleaned up old snapshot %s", d.name)
        except OSError:
            logger.warning("Failed to remove snapshot %s", d.name)
    return removed


async def cleanup_snapshots(instance: OpenClawInstance, keep_count: int = 3) -> int:
    return await asyncio.to_thread(_cleanup_snapshots_sync, instance, keep_count)
