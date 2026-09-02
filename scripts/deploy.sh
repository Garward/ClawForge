#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
runtime_root="${CLAWFORGE_RUNTIME_ROOT:-$(dirname "$repo_root")/runtime}"

if [[ "${1:-}" == "--build" ]]; then
    zig build \
        --build-file "$repo_root/build.zig" \
        --cache-dir "$repo_root/.zig-cache" \
        --global-cache-dir "$repo_root/.zig-global-cache"
fi

daemon="$repo_root/zig-out/bin/clawforged"
if [[ ! -x "$daemon" ]]; then
    echo "No built daemon found at $daemon" >&2
    echo "Run '$0 --build' first." >&2
    exit 1
fi

mkdir -p \
    "$runtime_root/zig-out/bin" \
    "$runtime_root/bridges" \
    "$runtime_root/tools" \
    "$runtime_root/scripts" \
    "$runtime_root/config/personas" \
    "$runtime_root/data"

install -m 0755 "$daemon" "$runtime_root/zig-out/bin/clawforged"
if [[ -x "$repo_root/zig-out/bin/clawforge" ]]; then
    install -m 0755 "$repo_root/zig-out/bin/clawforge" "$runtime_root/zig-out/bin/clawforge"
fi

install -m 0755 "$repo_root/restart.sh" "$runtime_root/restart.sh"
install -m 0755 "$repo_root/scripts/rebuild-active.sh" "$runtime_root/scripts/rebuild-active.sh"
install -m 0644 "$repo_root/requirements.txt" "$runtime_root/requirements.txt"
install -m 0644 "$repo_root/.env.example" "$runtime_root/.env.example"

find "$repo_root/bridges" -maxdepth 1 -type f -name '*.py' -exec install -m 0755 -t "$runtime_root/bridges" {} +
find "$repo_root/tools" -maxdepth 1 -type f -name '*.py' -exec install -m 0755 -t "$runtime_root/tools" {} +

# Runtime configuration is mutable. Seed it once and leave subsequent edits alone.
if [[ ! -e "$runtime_root/config/config.json" ]]; then
    install -m 0644 "$repo_root/config/config.json" "$runtime_root/config/config.json"
fi
if [[ ! -e "$runtime_root/config/personas/default.txt" ]]; then
    install -m 0644 "$repo_root/config/personas/default.txt" "$runtime_root/config/personas/default.txt"
fi

echo "Deployed ClawForge to $runtime_root"
echo "Runtime data and configuration were preserved."
