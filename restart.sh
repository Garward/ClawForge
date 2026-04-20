#!/bin/bash
# Quick daemon restart for testing
# SIGTERM first to let SQLite checkpoint the WAL cleanly
pkill -f clawforged 2>/dev/null
# The Discord bridge is spawned as a child of clawforged but when
# clawforged is killed the child often gets reparented and orphaned,
# leaving a duplicate bridge still connected to the Gateway (double
# replies to every @mention). Kill any stray bridge processes explicitly.
pkill -f "bridges/discord_bridge.py" 2>/dev/null
sleep 1
# Force kill only if it didn't exit gracefully
pkill -9 -f clawforged 2>/dev/null
pkill -9 -f "bridges/discord_bridge.py" 2>/dev/null
sleep 0.3
CLAWFORGE_ROOT="${CLAWFORGE_ROOT:-$(cd "$(dirname "$(readlink -f "$0")")" && pwd)}"
rm -f "$CLAWFORGE_ROOT/data/clawforge.sock"
cd "$CLAWFORGE_ROOT"

if [ "$1" = "build" ]; then
    zig build 2>&1 || exit 1
fi

if [ "$1" = "clean" ] || [ "$2" = "clean" ]; then
    sqlite3 data/workspace.db "DELETE FROM messages; DELETE FROM sessions;" 2>/dev/null
    echo "Cleaned messages and sessions"
fi

./zig-out/bin/clawforged 2>/tmp/clawforge.log &
sleep 1.5

if curl -s --max-time 2 http://127.0.0.1:8081/api/status > /dev/null 2>&1; then
    echo "Daemon running (PID $(pgrep -f clawforged))"
else
    echo "FAILED to start. Log:"
    cat /tmp/clawforge.log
    exit 1
fi
