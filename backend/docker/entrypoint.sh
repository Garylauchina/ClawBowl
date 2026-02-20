#!/bin/sh
if command -v Xvfb >/dev/null 2>&1; then
    Xvfb :99 -screen 0 1280x720x24 -nolisten tcp &
    export DISPLAY=:99
fi

if command -v dbus-daemon >/dev/null 2>&1; then
    mkdir -p /run/dbus
    dbus-daemon --system --nofork &
fi

exec openclaw gateway --bind lan --port 18789
