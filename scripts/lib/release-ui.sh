#!/usr/bin/env bash

# Shared terminal helpers for the release installer and updater.

if [[ -t 1 && "${TERM:-dumb}" != "dumb" && -z "${NO_COLOR:-}" ]]; then
    CF_BOLD=$'\033[1m'
    CF_GREEN=$'\033[32m'
    CF_YELLOW=$'\033[33m'
    CF_RED=$'\033[31m'
    CF_RESET=$'\033[0m'
else
    CF_BOLD=''
    CF_GREEN=''
    CF_YELLOW=''
    CF_RED=''
    CF_RESET=''
fi

cf_header() {
    printf '\n%s%s%s\n' "$CF_BOLD" "$1" "$CF_RESET"
    printf '%s\n' '----------------------------------------'
}

cf_step() {
    printf '\n%s==>%s %s\n' "$CF_BOLD" "$CF_RESET" "$1"
}

cf_ok() {
    printf '%sOK%s  %s\n' "$CF_GREEN" "$CF_RESET" "$1"
}

cf_info() {
    printf '    %s\n' "$1"
}

cf_warn() {
    printf '%sWARN%s %s\n' "$CF_YELLOW" "$CF_RESET" "$1" >&2
}

cf_die() {
    printf '%sERROR%s %s\n' "$CF_RED" "$CF_RESET" "$1" >&2
    exit 1
}

cf_is_interactive() {
    [[ "${CF_INTERACTIVE:-0}" == "1" ]]
}

cf_prompt_yes_no() {
    local prompt="$1"
    local default="${2:-yes}"
    local hint='[Y/n]'
    local answer=''

    if ! cf_is_interactive; then
        [[ "$default" == "yes" ]]
        return
    fi
    [[ "$default" == "no" ]] && hint='[y/N]'

    while true; do
        read -r -p "$prompt $hint " answer || answer=''
        answer="${answer:-$default}"
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            *) cf_warn 'Please answer yes or no.' ;;
        esac
    done
}

cf_prompt_value() {
    local prompt="$1"
    local default="$2"
    local answer=''

    if ! cf_is_interactive; then
        printf '%s' "$default"
        return
    fi

    read -r -p "$prompt [$default] " answer || answer=''
    printf '%s' "${answer:-$default}"
}

cf_command_version() {
    local command="$1"
    shift
    if command -v "$command" >/dev/null 2>&1; then
        "$command" "$@" 2>/dev/null | head -n 1
    else
        printf 'not found'
    fi
}
