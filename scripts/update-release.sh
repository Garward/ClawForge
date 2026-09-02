#!/usr/bin/env bash
set -euo pipefail

script_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ui_library="$script_root/lib/release-ui.sh"
[[ -r "$ui_library" ]] || { echo "Updater support file not found: $ui_library" >&2; exit 1; }
# shellcheck source=lib/release-ui.sh
source "$ui_library"

repository="${CLAWFORGE_UPDATE_REPOSITORY:-Garward/ClawForge}"
install_root="${CLAWFORGE_INSTALL_ROOT:-$script_root}"
assume_yes="${CLAWFORGE_ASSUME_YES:-0}"
interaction_mode=auto
force=false
check_only=false
restart_mode=auto

usage() {
    cat <<'EOF'
Usage: clawforge-update [options]

  -y, --yes              Accept recommended defaults without prompting
      --non-interactive  Disable prompts
      --check            Check for an update without installing it
      --force            Reinstall even when the latest version is installed
      --no-restart       Do not restart a running daemon after the update
  -h, --help             Show this help

Updates replace application files only. Existing .env, configuration,
personas, database, sessions, messages, knowledge, and skills are preserved.
EOF
}

while (($#)); do
    case "$1" in
        -y|--yes) assume_yes=1; interaction_mode=never ;;
        --non-interactive) interaction_mode=never ;;
        --check) check_only=true ;;
        --force) force=true ;;
        --no-restart) restart_mode=never ;;
        -h|--help) usage; exit 0 ;;
        *) cf_die "Unknown option: $1" ;;
    esac
    shift
done

if [[ "$interaction_mode" == auto && "$assume_yes" != 1 && -t 0 && -t 1 ]]; then
    CF_INTERACTIVE=1
else
    CF_INTERACTIVE=0
fi

cf_header 'ClawForge guided updater'
cf_info "Installation: $install_root"
cf_info 'Updates preserve .env, config, personas, and everything under data/.'

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) ;;
    *) cf_die 'Release updates currently support Linux x86_64, including Windows WSL, only.' ;;
esac

for command in curl python3 sha256sum; do
    command -v "$command" >/dev/null 2>&1 || cf_die "Required command not found: $command"
done

installed_version='unversioned'
if [[ -f "$install_root/VERSION" ]]; then
    installed_version="$(tr -d '[:space:]' < "$install_root/VERSION")"
fi

cf_step 'Checking GitHub for the latest release'
latest_redirect="https://github.com/$repository/releases/latest"
latest_url="$(curl -fsSL -o /dev/null -w '%{url_effective}' "$latest_redirect")"
tag="${latest_url##*/}"
version="${tag#v}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || cf_die "GitHub returned an invalid release tag: $tag"

cf_info "Installed version: $installed_version"
cf_info "Latest version:    $version"

if [[ "$installed_version" == "$version" && "$force" == false ]]; then
    cf_ok "ClawForge $version is already current."
    exit 0
fi
if [[ "$check_only" == true ]]; then
    cf_info 'An update is available. Run clawforge-update to install it.'
    exit 0
fi

cf_step 'Update plan'
cf_info "Download the v$version archive and checksum from $repository."
cf_info 'Verify SHA-256 before extracting anything.'
cf_info 'Replace application files while keeping all mutable configuration and workspace data.'

if cf_is_interactive && ! cf_prompt_yes_no "Update ClawForge from $installed_version to $version?" yes; then
    cf_info 'Update cancelled; nothing was changed.'
    exit 0
fi

archive_name="clawforge-${version}-linux-x86_64"
download_base="https://github.com/$repository/releases/download/$tag"
update_dir="$(mktemp -d "${TMPDIR:-/tmp}/clawforge-update.XXXXXX")"
trap 'rm -rf "$update_dir"' EXIT

cf_step 'Downloading release'
curl -fL --progress-bar "$download_base/$archive_name.zip" -o "$update_dir/$archive_name.zip"
curl -fL --progress-bar "$download_base/$archive_name.zip.sha256" -o "$update_dir/$archive_name.zip.sha256"

cf_step 'Verifying release checksum'
(cd "$update_dir" && sha256sum -c "$archive_name.zip.sha256")
cf_ok 'Release checksum is valid.'

cf_step 'Extracting verified release'
python3 -m zipfile -e "$update_dir/$archive_name.zip" "$update_dir"

was_running=false
if pgrep -f "$install_root/zig-out/bin/clawforged" >/dev/null 2>&1; then
    was_running=true
    cf_info 'The daemon is running and will be restarted after installation.'
else
    cf_info 'The daemon is stopped and will remain stopped.'
fi

cf_step 'Installing update'
bash "$update_dir/$archive_name/install.sh" \
    --yes \
    --no-start \
    --install-root "$install_root" \
    --bin-dir "${XDG_BIN_HOME:-$HOME/.local/bin}"

if [[ "$was_running" == true && "$restart_mode" != never ]]; then
    cf_step 'Restarting ClawForge'
    "$install_root/restart.sh"
fi

cf_header 'Update complete'
cf_ok "ClawForge was updated from $installed_version to $version."
cf_info "Configuration: $install_root/config/config.json"
cf_info "Persistent workspace: $install_root/data/workspace.db"
cf_info 'Run clawforge-update --check at any time to check without installing.'
