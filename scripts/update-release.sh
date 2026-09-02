#!/usr/bin/env bash
set -euo pipefail

repository="${CLAWFORGE_UPDATE_REPOSITORY:-Garward/ClawForge}"
script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
install_root="${CLAWFORGE_INSTALL_ROOT:-$script_root}"
latest_redirect="https://github.com/$repository/releases/latest"

for command in curl python3 sha256sum; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "Required command not found: $command" >&2
        exit 1
    fi
done

latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$latest_redirect")"
tag="${latest_url##*/}"
version="${tag#v}"
archive_name="clawforge-${version}-linux-x86_64"
download_base="https://github.com/$repository/releases/download/$tag"
installed_version=""

if [[ -f "$install_root/VERSION" ]]; then
    installed_version="$(tr -d '[:space:]' < "$install_root/VERSION")"
fi
if [[ "$installed_version" == "$version" && "${1:-}" != "--force" ]]; then
    echo "ClawForge $version is already installed."
    exit 0
fi

update_dir="$(mktemp -d "${TMPDIR:-/tmp}/clawforge-update.XXXXXX")"
trap 'rm -rf "$update_dir"' EXIT

curl -fL "$download_base/$archive_name.zip" -o "$update_dir/$archive_name.zip"
curl -fL "$download_base/$archive_name.zip.sha256" -o "$update_dir/$archive_name.zip.sha256"
(cd "$update_dir" && sha256sum -c "$archive_name.zip.sha256")
python3 -m zipfile -e "$update_dir/$archive_name.zip" "$update_dir"

was_running=false
if pgrep -f "$install_root/zig-out/bin/clawforged" >/dev/null 2>&1; then
    was_running=true
fi

bash "$update_dir/$archive_name/install.sh"

if [[ "$was_running" == true ]]; then
    "$install_root/restart.sh"
fi

echo "Updated ClawForge from ${installed_version:-an unversioned install} to $version."
