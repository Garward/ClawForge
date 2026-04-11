#!/bin/bash
# Quick daemon restart for testing
pkill -9 -f clawforged 2>/dev/null
sleep 0.3
rm -f /home/garward/Scripts/Tools/ClawForge/data/clawforge.sock
cd /home/garward/Scripts/Tools/ClawForge

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
