#!/usr/bin/env bash
set -euo pipefail

archive_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_root="${CLAWFORGE_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/clawforge}"
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) ;;
    *)
        echo "This package supports Linux x86_64, including WSL, only." >&2
        exit 1
        ;;
esac

for command in python3 install; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

mkdir -p \
    "$install_root/zig-out/bin" \
    "$install_root/bridges" \
    "$install_root/tools" \
    "$install_root/config/personas" \
    "$install_root/data" \
    "$bin_dir"

install -m 0755 "$archive_root/zig-out/bin/clawforged" "$install_root/zig-out/bin/clawforged"
install -m 0755 "$archive_root/zig-out/bin/clawforge" "$install_root/zig-out/bin/clawforge"
install -m 0755 "$archive_root/restart.sh" "$install_root/restart.sh"
install -m 0755 "$archive_root/update.sh" "$install_root/update.sh"
install -m 0644 "$archive_root/requirements.txt" "$install_root/requirements.txt"
install -m 0644 "$archive_root/VERSION" "$install_root/VERSION"
install -m 0644 "$archive_root/.env.example" "$install_root/.env.example"
install -m 0644 "$archive_root/config/personas/default.txt" "$install_root/config/personas/default.txt"
find "$archive_root/bridges" -maxdepth 1 -type f -name '*.py' -exec install -m 0755 -t "$install_root/bridges" {} +
find "$archive_root/tools" -maxdepth 1 -type f -name '*.py' -exec install -m 0755 -t "$install_root/tools" {} +

if [[ ! -e "$install_root/config/config.json" ]]; then
    install -m 0644 "$archive_root/config/config.json" "$install_root/config/config.json"
fi
if [[ ! -e "$install_root/.env" ]]; then
    install -m 0600 "$archive_root/.env.example" "$install_root/.env"
fi

if [[ "${CLAWFORGE_SKIP_PYTHON_DEPS:-0}" != "1" ]]; then
    if ! python3 -m venv "$install_root/.venv"; then
        echo "Python virtual environments are unavailable." >&2
        echo "Install your distribution's python3-venv package and rerun this installer." >&2
        exit 1
    fi
    "$install_root/.venv/bin/python" -m pip install --upgrade pip
    "$install_root/.venv/bin/python" -m pip install -r "$install_root/requirements.txt"
fi

ln -sfn "$install_root/zig-out/bin/clawforged" "$bin_dir/clawforged"
ln -sfn "$install_root/zig-out/bin/clawforge" "$bin_dir/clawforge"
ln -sfn "$install_root/zig-out/bin/clawforge" "$bin_dir/clawforge-cli"
ln -sfn "$install_root/restart.sh" "$bin_dir/clawforge-restart"
ln -sfn "$install_root/update.sh" "$bin_dir/clawforge-update"

echo "Installed ClawForge in $install_root"
echo "Edit $install_root/.env, then run $bin_dir/clawforge-restart"
echo "Future releases can be installed with $bin_dir/clawforge-update"
