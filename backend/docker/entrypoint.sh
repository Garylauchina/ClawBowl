#!/bin/sh
set -e

# Make all new files world-readable so the host backend (non-root) can
# read session JSONL files for reconciliation (see DESIGN.md §21.2).
umask 0022

# Fix permissions on existing session files created with restrictive umask
chmod -R o+rX /data/config/agents 2>/dev/null || true

# Clean up stale X lock files (from container restart)
rm -f /tmp/.X99-lock /tmp/.X11-unix/X99

if command -v dbus-daemon >/dev/null 2>&1; then
    mkdir -p /run/dbus
    dbus-daemon --system --nofork &
fi

if command -v Xvfb >/dev/null 2>&1; then
    Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
    XVFB_PID=$!
    export DISPLAY=:99
    # Wait until display is ready (up to 3s)
    for i in 1 2 3 4 5 6; do
        if xdpyinfo -display :99 >/dev/null 2>&1; then
            break
        fi
        sleep 0.5
    done
fi

# Use --init-like wrapper so zombie children get reaped
exec openclaw gateway --bind lan --port 18789
