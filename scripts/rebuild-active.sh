#!/usr/bin/env bash
set -euo pipefail

runtime_root="${CLAWFORGE_RUNTIME_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
source_root="${CLAWFORGE_SOURCE_ROOT:-$(dirname "$runtime_root")/ClawForge}"
log_file="${CLAWFORGE_REBUILD_LOG:-/tmp/clawforge_rebuild.log}"
delay="${1:-5}"

if [[ ! -x "$source_root/scripts/deploy.sh" ]]; then
    echo "ClawForge source checkout not found at $source_root" >&2
    exit 1
fi

nohup bash -c '
    set -e
    sleep "$1"

    waited=0
    while [[ "$waited" -lt 120 ]]; do
        active="$(ss -tn 2>/dev/null | grep ":8081" | grep -c ESTAB || true)"
        [[ "$active" -le 1 ]] && break
        sleep 1
        waited=$((waited + 1))
    done

    echo "$(date): Building source (waited ${waited}s for streams)..." > "$4"
    if zig build --build-file "$2/build.zig" >> "$4" 2>&1; then
        echo "$(date): Build succeeded; deploying..." >> "$4"
        CLAWFORGE_RUNTIME_ROOT="$3" "$2/scripts/deploy.sh" >> "$4" 2>&1
        "$3/restart.sh" >> "$4" 2>&1
        echo "$(date): Deploy and restart complete" >> "$4"
    else
        echo "$(date): Build failed; active daemon was not changed" >> "$4"
    fi
' _ "$delay" "$source_root" "$runtime_root" "$log_file" </dev/null >/dev/null 2>&1 &

echo "Rebuild scheduled. Log: $log_file"
