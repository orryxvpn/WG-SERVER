#!/usr/bin/env bash
# common.sh — shared logging, color, and utility helpers for wg-tunnel-setup.
#
# This file is sourced by setup.sh and other lib/ files. It must not run any
# action when sourced beyond setting variables and defining functions.

# Treat sourcing twice as a no-op.
if [[ -n "${_WG_COMMON_SOURCED:-}" ]]; then
    return 0
fi
_WG_COMMON_SOURCED=1

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SCRIPT_VERSION="${SCRIPT_VERSION:-1.0.0}"
LOG_FILE="${LOG_FILE:-/var/log/wg-tunnel-setup.log}"
WG_DIR="${WG_DIR:-/etc/wireguard}"
WG_IF="${WG_IF:-wg0}"
WG_PORT="${WG_PORT:-51820}"
WG_NET_CIDR="${WG_NET_CIDR:-10.66.66.0/24}"
WG_EGRESS_IP="${WG_EGRESS_IP:-10.66.66.1}"
WG_INGRESS_IP="${WG_INGRESS_IP:-10.66.66.2}"
WG_TABLE_ID="${WG_TABLE_ID:-200}"
WG_TABLE_NAME="${WG_TABLE_NAME:-wgout}"
WG_FWMARK="${WG_FWMARK:-0x1}"
# shellcheck disable=SC2034  # used by lib/egress.sh and lib/ingress.sh
WG_MARKER="# wg-tunnel-setup v${SCRIPT_VERSION}"

# ------------------------------------------------------------------------------
# Color setup
# ------------------------------------------------------------------------------
# Disable colors when stdout is not a TTY or when NO_COLOR is set (per
# https://no-color.org/).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_CYAN=$'\033[36m'
else
    C_RESET=''
    C_BOLD=''
    C_RED=''
    C_GREEN=''
    C_YELLOW=''
    C_BLUE=''
    C_CYAN=''
fi

# ------------------------------------------------------------------------------
# Logging
# ------------------------------------------------------------------------------

# log_init — make sure the log file exists with safe permissions.
log_init() {
    local dir
    dir="$(dirname "$LOG_FILE")"
    mkdir -p "$dir"
    : >>"$LOG_FILE"
    chmod 600 "$LOG_FILE" 2>/dev/null || true
}

# _log_to_file <level> <message>
# Append a timestamped message to the log file. Never print to stdout.
_log_to_file() {
    local level="$1"
    shift
    printf '%s [%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$level" "$*" \
        >>"$LOG_FILE" 2>/dev/null || true
}

# log_info / log_warn / log_error / log_success / log_step
# All accept a free-form message. Output goes to stdout (with color) and the
# logfile (without color). They never echo private keys — the caller's
# responsibility.
log_info() {
    _log_to_file "INFO" "$*"
    printf '%s[INFO]%s %s\n' "$C_BLUE" "$C_RESET" "$*"
}

log_warn() {
    _log_to_file "WARN" "$*"
    printf '%s[WARN]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2
}

log_error() {
    _log_to_file "ERROR" "$*"
    printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
}

log_success() {
    _log_to_file "OK" "$*"
    printf '%s[ OK ]%s %s\n' "$C_GREEN" "$C_RESET" "$*"
}

log_step() {
    _log_to_file "STEP" "$*"
    printf '\n%s==>%s %s%s%s\n' "$C_CYAN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"
}

# die <message> — log error and exit non-zero.
die() {
    log_error "$*"
    exit 1
}

# ------------------------------------------------------------------------------
# UI helpers
# ------------------------------------------------------------------------------

# banner <line1> [<line2> ...]
# Print a boxed banner. Used for section headers in user-facing output.
banner() {
    local line
    local width=58
    printf '%s' "$C_BOLD"
    printf '=%.0s' $(seq 1 "$width"); printf '\n'
    for line in "$@"; do
        printf '  %s\n' "$line"
    done
    printf '=%.0s' $(seq 1 "$width"); printf '\n'
    printf '%s' "$C_RESET"
}

# pause <prompt>
# Wait for user to press ENTER. Reads from /dev/tty so it works under
# `curl … | sudo bash`.
pause() {
    local prompt="${1:-Нажмите ENTER чтобы продолжить...}"
    local _unused
    if [[ -r /dev/tty ]]; then
        # shellcheck disable=SC2034  # _unused intentionally discarded
        IFS= read -r -p "$prompt" _unused </dev/tty || true
    else
        # shellcheck disable=SC2034
        IFS= read -r -p "$prompt" _unused || true
    fi
}

# read_tty <varname> <prompt> [<timeout-seconds>]
# Read a single line from /dev/tty (so it works in `curl|bash`) into the named
# variable. Defaults to a 600-second timeout.
read_tty() {
    local _varname="$1"
    local _prompt="$2"
    local _timeout="${3:-600}"
    local _value=""
    local _src="/dev/tty"
    [[ -r "$_src" ]] || _src="/dev/stdin"
    if ! IFS= read -r -t "$_timeout" -p "$_prompt" _value <"$_src"; then
        die "Превышен таймаут ввода (${_timeout}с)."
    fi
    printf -v "$_varname" '%s' "$_value"
}

# confirm <prompt> [<default>]
# Ask a yes/no question. Default is "n" unless specified. Returns 0 on yes.
confirm() {
    local prompt="$1"
    local default="${2:-n}"
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    local answer=""
    read_tty answer "$prompt $hint: "
    answer="${answer,,}"
    answer="${answer// /}"
    [[ -z "$answer" ]] && answer="$default"
    [[ "$answer" == "y" || "$answer" == "yes" ]]
}

# trim <string>
# Echo the input with leading/trailing whitespace (incl. newlines) removed.
trim() {
    local s="$*"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ------------------------------------------------------------------------------
# Misc utilities
# ------------------------------------------------------------------------------

# require_root — exit if not running as UID 0.
require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        die "Скрипт должен запускаться с правами root. Используйте sudo."
    fi
}

# umask_secure — set umask to 077 so newly created files are owner-only.
umask_secure() {
    umask 077
}

# detect_default_iface — print the name of the iface bound to the default
# IPv4 route. Empty string if none.
detect_default_iface() {
    ip -4 route show default 2>/dev/null \
        | awk '/^default/ {print $5; exit}'
}

# detect_public_ipv4 — print the public IPv4 of this host using a couple of
# providers. Empty string if all fail.
detect_public_ipv4() {
    local svc ip
    for svc in "https://api.ipify.org" "https://ifconfig.me" \
               "https://ipv4.icanhazip.com"; do
        ip="$(curl -4 -fsS --max-time 5 "$svc" 2>/dev/null || true)"
        ip="$(trim "$ip")"
        if [[ -n "$ip" ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# detect_os — populate OS_ID, OS_VERSION_ID, OS_PRETTY from /etc/os-release.
# These are read by check_supported_os() and the role menu in setup.sh.
detect_os() {
    # shellcheck disable=SC2034  # consumed by callers
    OS_ID=""
    # shellcheck disable=SC2034
    OS_VERSION_ID=""
    # shellcheck disable=SC2034
    OS_PRETTY=""
    if [[ -r /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        # shellcheck disable=SC2034
        OS_ID="${ID:-}"
        # shellcheck disable=SC2034
        OS_VERSION_ID="${VERSION_ID:-}"
        # shellcheck disable=SC2034
        OS_PRETTY="${PRETTY_NAME:-}"
    fi
}

# atomic_write <path> [<mode>]
# Read stdin and write it atomically to <path> with the given mode (default
# 0600). Uses a tempfile in the same directory + mv to avoid half-written files.
atomic_write() {
    local path="$1"
    local mode="${2:-600}"
    local dir tmp
    dir="$(dirname "$path")"
    mkdir -p "$dir"
    tmp="$(mktemp "$dir/.wgtmp.XXXXXX")"
    chmod "$mode" "$tmp"
    cat >"$tmp"
    mv -f "$tmp" "$path"
    chmod "$mode" "$path"
}

# install_packages <pkg> [<pkg> ...]
# Install Debian/Ubuntu packages non-interactively. Skips already-installed.
install_packages() {
    local missing=()
    local p
    for p in "$@"; do
        if ! dpkg -s "$p" >/dev/null 2>&1; then
            missing+=("$p")
        fi
    done
    if [[ ${#missing[@]} -eq 0 ]]; then
        log_info "Все пакеты уже установлены: $*"
        return 0
    fi
    log_info "Устанавливаются пакеты: ${missing[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1 || \
        die "apt-get update упал. См. $LOG_FILE"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold" \
        "${missing[@]}" >>"$LOG_FILE" 2>&1 \
        || die "Не удалось установить пакеты: ${missing[*]}. См. $LOG_FILE"
}

# write_sysctl <file> <body>
# Write a sysctl drop-in and apply it. <file> is the basename in
# /etc/sysctl.d/ (must end in .conf). <body> is the file contents.
write_sysctl() {
    local file="$1"
    local body="$2"
    local path="/etc/sysctl.d/$file"
    printf '%s\n' "$body" | atomic_write "$path" 644
    sysctl --system >>"$LOG_FILE" 2>&1 || \
        log_warn "sysctl --system завершился с ошибкой; см. $LOG_FILE"
}
