#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
package_only=false
if [[ "${1:-}" == "--package-only" ]]; then
    package_only=true
    shift
fi
version="${1:-$(tr -d '[:space:]' < "$repo_root/VERSION")}"
archive_name="clawforge-${version}-linux-x86_64"
dist_dir="$repo_root/dist"
package_dir="$dist_dir/$archive_name"
release_cache="$(mktemp -d "${TMPDIR:-/tmp}/clawforge-release.XXXXXX")"
trap 'rm -rf "$release_cache"' EXIT

if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Invalid release version: $version" >&2
    exit 1
fi

build_args=(
    --build-file "$repo_root/build.zig"
    --cache-dir "$release_cache/local"
    --global-cache-dir "$release_cache/global"
    -Doptimize=ReleaseSafe
    -Dcpu=baseline
)
if [[ "$package_only" == false ]]; then
    if [[ -n "${CLAWFORGE_RELEASE_TARGET:-}" ]]; then
        build_args+=("-Dtarget=$CLAWFORGE_RELEASE_TARGET")
    fi
    zig build "${build_args[@]}"
fi

rm -rf "$package_dir"
mkdir -p \
    "$package_dir/zig-out/bin" \
    "$package_dir/bridges" \
    "$package_dir/tools" \
    "$package_dir/config/personas"

install -m 0755 "$repo_root/zig-out/bin/clawforged" "$package_dir/zig-out/bin/clawforged"
install -m 0755 "$repo_root/zig-out/bin/clawforge" "$package_dir/zig-out/bin/clawforge"
install -m 0755 "$repo_root/restart.sh" "$package_dir/restart.sh"
install -m 0755 "$repo_root/scripts/install-release.sh" "$package_dir/install.sh"
install -m 0755 "$repo_root/scripts/update-release.sh" "$package_dir/update.sh"
install -m 0644 "$repo_root/requirements.txt" "$package_dir/requirements.txt"
install -m 0644 "$repo_root/.env.example" "$package_dir/.env.example"
install -m 0644 "$repo_root/config/config.json" "$package_dir/config/config.json"
install -m 0644 "$repo_root/config/personas/default.txt" "$package_dir/config/personas/default.txt"
install -m 0644 "$repo_root/LICENSE" "$package_dir/LICENSE"
install -m 0644 "$repo_root/README.md" "$package_dir/README.md"
install -m 0644 "$repo_root/VERSION" "$package_dir/VERSION"
find "$repo_root/bridges" -maxdepth 1 -type f -name '*.py' -exec install -m 0755 -t "$package_dir/bridges" {} +
find "$repo_root/tools" -maxdepth 1 -type f -name '*.py' -exec install -m 0755 -t "$package_dir/tools" {} +

(cd "$dist_dir" && python3 -m zipfile -c "$archive_name.zip" "$archive_name")
(cd "$dist_dir" && sha256sum "$archive_name.zip" > "$archive_name.zip.sha256")
rm -rf "$package_dir"
echo "Created $dist_dir/$archive_name.zip"
