#!/usr/bin/env bash
set -euo pipefail

archive_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ui_library="$archive_root/lib/release-ui.sh"
[[ -r "$ui_library" ]] || { echo "Installer support file not found: $ui_library" >&2; exit 1; }
# shellcheck source=lib/release-ui.sh
source "$ui_library"

install_root="${CLAWFORGE_INSTALL_ROOT:-${XDG_DATA_HOME:-$HOME/.local/share}/clawforge}"
bin_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
assume_yes="${CLAWFORGE_ASSUME_YES:-0}"
interaction_mode=auto
install_python_deps=true
[[ "${CLAWFORGE_SKIP_PYTHON_DEPS:-0}" == 1 ]] && install_python_deps=false
start_mode=ask

usage() {
    cat <<'EOF'
Usage: ./install.sh [options]

Guided install options:
  -y, --yes              Accept recommended defaults without prompting
      --non-interactive  Disable prompts (same defaults as --yes)
      --install-root DIR Install application and persistent data under DIR
      --bin-dir DIR      Put command launchers under DIR
      --skip-python-deps Do not create/update the private Python environment
      --start            Start ClawForge after installation
      --no-start         Do not start ClawForge after installation
  -h, --help             Show this help

No Anthropic, Codex, or other API token is required to install or start.
Existing .env, config/config.json, config/personas, and data are preserved.
EOF
}

while (($#)); do
    case "$1" in
        -y|--yes) assume_yes=1; interaction_mode=never ;;
        --non-interactive) interaction_mode=never ;;
        --install-root)
            (($# >= 2)) || cf_die '--install-root requires a directory.'
            install_root="$2"
            shift
            ;;
        --bin-dir)
            (($# >= 2)) || cf_die '--bin-dir requires a directory.'
            bin_dir="$2"
            shift
            ;;
        --skip-python-deps) install_python_deps=false ;;
        --start) start_mode=yes ;;
        --no-start) start_mode=no ;;
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

cf_header 'ClawForge guided installer'
cf_info 'Installs for your user account; root access is not needed.'
cf_info 'No model-provider token is required to install or start ClawForge.'
cf_info 'Application files are replaceable; configuration and workspace data are persistent.'

case "$(uname -s)-$(uname -m)" in
    Linux-x86_64) cf_ok 'Supported Linux x86_64 system detected.' ;;
    *) cf_die 'This package supports Linux x86_64, including Windows WSL, only.' ;;
esac

if grep -qi microsoft /proc/version 2>/dev/null; then
    cf_ok 'Windows WSL detected.'
fi

for command in python3 install; do
    command -v "$command" >/dev/null 2>&1 || cf_die "Required command not found: $command"
done
cf_info "Python: $(cf_command_version python3 --version)"

if cf_is_interactive; then
    install_root="$(cf_prompt_value 'Installation and data directory' "$install_root")"
    bin_dir="$(cf_prompt_value 'Command launcher directory' "$bin_dir")"
fi

package_version="$(tr -d '[:space:]' < "$archive_root/VERSION")"
installed_version=''
if [[ -f "$install_root/VERSION" ]]; then
    installed_version="$(tr -d '[:space:]' < "$install_root/VERSION")"
fi

cf_step 'Installation plan'
cf_info "Package version: $package_version"
cf_info "Application and data: $install_root"
cf_info "Command launchers: $bin_dir"
if [[ -n "$installed_version" ]]; then
    cf_info "Existing version: $installed_version"
    cf_ok 'Existing .env, config, personas, database, sessions, messages, and skills will be kept.'
else
    cf_info 'A new configuration and workspace will be created.'
fi

if [[ "$install_python_deps" == true ]] && cf_is_interactive; then
    if ! cf_prompt_yes_no 'Install Python packages for Discord, research, and browser tools?' yes; then
        install_python_deps=false
    fi
fi
if [[ "$install_python_deps" == true ]]; then
    cf_info 'Python tools: install/update a private virtual environment'
else
    cf_warn 'Optional Python tool dependencies will be skipped.'
fi

if cf_is_interactive && ! cf_prompt_yes_no 'Continue with this installation?' yes; then
    cf_info 'Installation cancelled; nothing was changed.'
    exit 0
fi

cf_step 'Installing application files'
mkdir -p \
    "$install_root/zig-out/bin" \
    "$install_root/bridges" \
    "$install_root/tools" \
    "$install_root/config/personas" \
    "$install_root/data" \
    "$install_root/lib" \
    "$bin_dir"

install -m 0755 "$archive_root/zig-out/bin/clawforged" "$install_root/zig-out/bin/clawforged"
install -m 0755 "$archive_root/zig-out/bin/clawforge" "$install_root/zig-out/bin/clawforge"
install -m 0755 "$archive_root/restart.sh" "$install_root/restart.sh"
install -m 0755 "$archive_root/update.sh" "$install_root/update.sh"
install -m 0644 "$archive_root/lib/release-ui.sh" "$install_root/lib/release-ui.sh"
install -m 0644 "$archive_root/requirements.txt" "$install_root/requirements.txt"
install -m 0644 "$archive_root/VERSION" "$install_root/VERSION"
install -m 0644 "$archive_root/.env.example" "$install_root/.env.example"
find "$archive_root/bridges" -maxdepth 1 -type f -name '*.py' -exec install -m 0755 -t "$install_root/bridges" {} +
find "$archive_root/tools" -maxdepth 1 -type f -name '*.py' -exec install -m 0755 -t "$install_root/tools" {} +

if [[ ! -e "$install_root/config/config.json" ]]; then
    install -m 0644 "$archive_root/config/config.json" "$install_root/config/config.json"
fi
if [[ ! -e "$install_root/config/personas/default.txt" ]]; then
    install -m 0644 "$archive_root/config/personas/default.txt" "$install_root/config/personas/default.txt"
fi
if [[ ! -e "$install_root/.env" ]]; then
    install -m 0600 "$archive_root/.env.example" "$install_root/.env"
fi

if [[ "$install_python_deps" == true ]]; then
    cf_step 'Preparing Python tools'
    if ! python3 -m venv "$install_root/.venv"; then
        cf_die "Python virtual environments are unavailable. Install your distribution's python3-venv package and rerun this installer."
    fi
    "$install_root/.venv/bin/python" -m pip install --disable-pip-version-check --upgrade pip
    "$install_root/.venv/bin/python" -m pip install --disable-pip-version-check -r "$install_root/requirements.txt"

    if ! grep -q '^[[:space:]]*CLAWFORGE_PYTHON=' "$install_root/.env"; then
        printf '\n# Managed by the ClawForge installer.\nCLAWFORGE_PYTHON=%s\n' \
            "$install_root/.venv/bin/python" >> "$install_root/.env"
    fi
    cf_ok 'Private Python environment is ready and selected in .env.'
fi

ln -sfn "$install_root/zig-out/bin/clawforged" "$bin_dir/clawforged"
ln -sfn "$install_root/zig-out/bin/clawforge" "$bin_dir/clawforge"
ln -sfn "$install_root/zig-out/bin/clawforge" "$bin_dir/clawforge-cli"
ln -sfn "$install_root/restart.sh" "$bin_dir/clawforge-restart"
ln -sfn "$install_root/update.sh" "$bin_dir/clawforge-update"

cf_step 'Model provider check'
provider_ready=false
if command -v curl >/dev/null 2>&1 && curl -fsS --max-time 1 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    configured_ollama_model="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["ollama"]["default_model"])' "$install_root/config/config.json" 2>/dev/null || printf 'qwen3:4b')"
    if command -v ollama >/dev/null 2>&1 && ollama list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$configured_ollama_model"; then
        cf_ok "Ollama is ready with $configured_ollama_model; no API token is needed."
        provider_ready=true
    else
        cf_warn "Ollama is running, but the configured model $configured_ollama_model was not found."
        if cf_is_interactive && command -v ollama >/dev/null 2>&1 && cf_prompt_yes_no "Download $configured_ollama_model now?" yes; then
            ollama pull "$configured_ollama_model"
            cf_ok "$configured_ollama_model is ready."
            provider_ready=true
        else
            cf_info "Download it later with: ollama pull $configured_ollama_model"
        fi
    fi
fi
if [[ -s "$HOME/.codex/auth.json" ]]; then
    cf_ok 'An optional Codex login is available.'
    provider_ready=true
fi
if grep -Eq '^[[:space:]]*OPENROUTER_API_KEY=.+$' "$install_root/.env"; then
    cf_ok 'An optional OpenRouter API key is configured.'
    provider_ready=true
fi
if [[ -s "$install_root/data/anthropic-token.txt" ]]; then
    cf_ok 'An optional Anthropic token is configured.'
    provider_ready=true
fi

if [[ "$provider_ready" == false ]]; then
    cf_warn 'No running model provider was detected. ClawForge can still start and be configured afterward.'
    cf_info 'Token-free default: install Ollama, run ollama serve, then run ollama pull qwen3:4b.'
    cf_info 'Optional hosted providers: Codex login, OpenRouter, OpenAI, or Anthropic.'
    cf_info "Provider routing and models: $install_root/config/config.json"
    cf_info "Optional secrets and path overrides: $install_root/.env"
fi

if [[ ":$PATH:" != *":$bin_dir:"* ]]; then
    cf_warn "$bin_dir is not currently on PATH."
    cf_info "Add this to your shell profile: export PATH=\"$bin_dir:\$PATH\""
fi

should_start=false
case "$start_mode" in
    yes) should_start=true ;;
    no) should_start=false ;;
    ask)
        if cf_is_interactive && cf_prompt_yes_no 'Start ClawForge now?' yes; then
            should_start=true
        fi
        ;;
esac

if [[ "$should_start" == true ]]; then
    command -v curl >/dev/null 2>&1 || cf_die 'Starting ClawForge requires curl for its health check.'
    cf_step 'Starting ClawForge'
    "$install_root/restart.sh"
fi

cf_header 'Installation complete'
cf_ok "ClawForge $package_version is installed in $install_root"
cf_info 'Web interface: http://127.0.0.1:8081'
cf_info "Start or restart: $bin_dir/clawforge-restart"
cf_info "Install future releases: $bin_dir/clawforge-update"
cf_info "Configuration: $install_root/config/config.json"
cf_info "Secrets and overrides: $install_root/.env"
cf_info "Sessions, messages, knowledge, and skills: $install_root/data/workspace.db"
