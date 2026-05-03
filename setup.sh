#!/usr/bin/env bash
# setup.sh — interactive WireGuard tunnel installer for INGRESS↦EGRESS schema.
#
# Usage:
#   sudo bash setup.sh                              # local checkout
#   curl -fsSL <pinned-url>/setup.sh | sudo bash    # one-liner
#
# The script auto-detects whether lib/ files are next to it (local checkout)
# or whether it has to download them from the pinned release tag (curl|bash).
# In both cases it ends up with the same set of helpers loaded.

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants — keep these in sync with lib/common.sh.
# ------------------------------------------------------------------------------
SCRIPT_VERSION="1.0.2"
REPO_SLUG="${WG_REPO_SLUG:-orryxvpn/wg-server}"
REPO_REF="${WG_REPO_REF:-v${SCRIPT_VERSION}}"
LIB_FILES=("common.sh" "checks.sh" "prompts.sh" "egress.sh" "ingress.sh")
# Set by load_libs after we know whether we're using a local checkout
# or a downloaded copy. Surfaced in the role-selection banner (in
# lib/prompts.sh) so the user can see at a glance which build they
# are running.
# shellcheck disable=SC2034  # consumed by lib/prompts.sh prompt_role
WG_SOURCE_INFO=""

LOG_FILE="${LOG_FILE:-/var/log/wg-tunnel-setup.log}"
LIB_DIR=""        # set by load_libs
TMP_LIB_DIR=""    # only used in curl|bash mode; cleaned on EXIT

# ------------------------------------------------------------------------------
# Bootstrap helpers (must be self-sufficient — common.sh isn't loaded yet).
# ------------------------------------------------------------------------------

# _bootstrap_die <msg> — print red error and exit. Used before common.sh loads.
_bootstrap_die() {
    if [[ -t 2 ]]; then
        printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2
    else
        printf '[ERROR] %s\n' "$*" >&2
    fi
    exit 1
}

# script_dir — best-effort directory of this script. Empty if we're running
# from stdin (curl|bash) and BASH_SOURCE is not a real file.
script_dir() {
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && -f "$src" ]]; then
        ( cd -- "$(dirname -- "$src")" && pwd )
        return 0
    fi
    printf ''
}

# load_libs — locate and source all lib/<name>.sh files.
#
# Search order:
#   1. <script_dir>/lib/<name>.sh   (a local checkout)
#   2. ./lib/<name>.sh              (cwd, if user cd'd to the repo)
#   3. download from raw.githubusercontent.com at $REPO_REF (curl|bash mode)
load_libs() {
    local sdir
    sdir="$(script_dir || true)"

    local candidate
    for candidate in "$sdir/lib" "./lib"; do
        if [[ -n "$candidate" && -d "$candidate" \
                && -f "$candidate/${LIB_FILES[0]}" ]]; then
            LIB_DIR="$candidate"
            break
        fi
    done

    if [[ -z "$LIB_DIR" ]]; then
        _bootstrap_download_libs
        LIB_DIR="$TMP_LIB_DIR"
        # shellcheck disable=SC2034  # read by lib/prompts.sh prompt_role
        WG_SOURCE_INFO="downloaded from ref=${REPO_REF}"
    else
        # shellcheck disable=SC2034  # read by lib/prompts.sh prompt_role
        WG_SOURCE_INFO="local: ${LIB_DIR}"
    fi

    local f
    for f in "${LIB_FILES[@]}"; do
        if [[ ! -f "$LIB_DIR/$f" ]]; then
            _bootstrap_die "Не найден lib-файл: $LIB_DIR/$f"
        fi
        # shellcheck disable=SC1090
        . "$LIB_DIR/$f"
    done
}

# _bootstrap_download_libs — fetch lib/*.sh from the pinned tag into a tempdir.
_bootstrap_download_libs() {
    if ! command -v curl >/dev/null 2>&1; then
        _bootstrap_die "Не найден curl, нужен для загрузки lib/. Установите: apt-get install -y curl"
    fi
    TMP_LIB_DIR="$(mktemp -d -t wg-tunnel-setup.XXXXXX)"
    chmod 700 "$TMP_LIB_DIR"
    trap '_bootstrap_cleanup' EXIT

    local base="https://raw.githubusercontent.com/${REPO_SLUG}/${REPO_REF}/lib"
    printf 'Загрузка lib/ из %s ...\n' "$base" >&2
    local f
    for f in "${LIB_FILES[@]}"; do
        if ! curl -fsSL --retry 3 --retry-delay 2 --max-time 30 \
                "$base/$f" -o "$TMP_LIB_DIR/$f"; then
            _bootstrap_die "Не удалось загрузить $base/$f"
        fi
    done
}

# _bootstrap_cleanup — remove temp lib dir if we created one.
_bootstrap_cleanup() {
    if [[ -n "${TMP_LIB_DIR:-}" && -d "$TMP_LIB_DIR" ]]; then
        rm -rf -- "$TMP_LIB_DIR"
    fi
}

# ------------------------------------------------------------------------------
# Error / exit handling (installed AFTER common.sh is loaded so we get
# colorized output, but bootstrap errors above don't depend on it).
# ------------------------------------------------------------------------------
_on_err() {
    local rc=$? line=$1 cmd=$2
    log_error "Сбой на строке ${line}: \`${cmd}\` (код ${rc})"
    log_error "Подробнее: ${LOG_FILE}"
}

_on_exit() {
    local rc=$?
    if (( rc != 0 )); then
        log_warn "Скрипт завершился с ошибкой (код ${rc})."
        # Best-effort: if wg-quick is enabled but failing, surface that hint.
        if systemctl is-failed --quiet "wg-quick@${WG_IF}" 2>/dev/null; then
            log_warn "wg-quick@${WG_IF} в состоянии failed — см. journalctl -u wg-quick@${WG_IF}"
        fi
    fi
    _bootstrap_cleanup
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
    # Handle --version / -V before any side effects so users can quickly
    # check which build they're about to run.
    case "${1:-}" in
        -V|--version)
            printf 'wg-tunnel-setup %s\n' "$SCRIPT_VERSION"
            exit 0
            ;;
    esac

    load_libs
    log_init
    _log_to_file "INFO" "=== wg-tunnel-setup v${SCRIPT_VERSION} starting ==="
    _log_to_file "INFO" "argv: $*"

    # Now that logging is up, install our error/exit traps.
    trap '_on_err "$LINENO" "$BASH_COMMAND"' ERR
    trap '_on_exit' EXIT

    require_root
    check_systemd
    check_apt
    require_command curl
    log_step "Preflight checks"
    check_supported_os
    check_internet
    log_success "Базовые проверки пройдены"

    # Detect environment.
    local default_iface public_ip hostname_str os_str
    default_iface="$(detect_default_iface || true)"
    [[ -z "$default_iface" ]] && default_iface="(не определено)"
    public_ip="$(detect_public_ipv4 || true)"
    [[ -z "$public_ip" ]] && public_ip="(не определено)"
    hostname_str="$(hostname 2>/dev/null || echo unknown)"
    os_str="${OS_PRETTY:-${OS_ID:-unknown}}"

    local role
    role="$(prompt_role "$public_ip" "$default_iface" "$hostname_str" "$os_str")"
    _log_to_file "INFO" "role=$role"

    case "$role" in
        egress)
            if ! check_existing_install; then
                exit 0
            fi
            # If reinstall was requested, wipe first.
            if [[ -f "$WG_DIR/wg0.conf" ]]; then
                _do_uninstall_role egress
            fi
            egress_run "$public_ip" "$default_iface"
            ;;
        ingress)
            if ! check_existing_install; then
                exit 0
            fi
            if [[ -f "$WG_DIR/wg0.conf" ]]; then
                _do_uninstall_role ingress
            fi
            ingress_run "$public_ip" "$default_iface"
            ;;
        uninstall)
            local urole
            urole="$(prompt_uninstall_role)"
            case "$urole" in
                egress)  _do_uninstall_role egress  ;;
                ingress) _do_uninstall_role ingress ;;
                both)    _do_uninstall_role both    ;;
                cancel)  log_info "Отмена."; exit 0 ;;
            esac
            log_success "Установка удалена. Логи: $LOG_FILE"
            ;;
        quit)
            log_info "Выход."
            exit 0
            ;;
        *)
            die "Неизвестная роль: $role"
            ;;
    esac
}

# _do_uninstall_role <role> — invoke the uninstall logic for a given role.
# Defined here (rather than in lib/) because it's shared between top-level
# uninstall and the reinstall-on-existing path.
_do_uninstall_role() {
    local role="$1"
    log_step "Удаление установки (role=${role})"

    if systemctl list-unit-files 2>/dev/null \
            | grep -q "^wg-quick@${WG_IF}\.service"; then
        systemctl disable --now "wg-quick@${WG_IF}" >>"$LOG_FILE" 2>&1 || true
    fi

    rm -f "$WG_DIR/wg0.conf"
    rm -f "$WG_DIR/egress_private.key" "$WG_DIR/egress_public.key"
    rm -f "$WG_DIR/ingress_private.key" "$WG_DIR/ingress_public.key"
    rm -f "$WG_DIR/wg.psk"

    if [[ "$role" == "egress" || "$role" == "both" ]]; then
        rm -f /etc/sysctl.d/99-wg-egress.conf
    fi
    if [[ "$role" == "ingress" || "$role" == "both" ]]; then
        rm -f /etc/sysctl.d/99-wg-ingress.conf
        # Try to remove leftover policy routing live (safe: silent if absent).
        ip rule del fwmark "$WG_FWMARK" lookup "$WG_TABLE_NAME" priority 100 \
            >/dev/null 2>&1 || true
        ip route flush table "$WG_TABLE_NAME" >/dev/null 2>&1 || true
        # Remove rt_tables entry, idempotent.
        if [[ -f /etc/iproute2/rt_tables ]]; then
            sed -i.bak \
                -e "/^${WG_TABLE_ID}[[:space:]]\\+${WG_TABLE_NAME}\\b/d" \
                /etc/iproute2/rt_tables
            rm -f /etc/iproute2/rt_tables.bak
        fi
    fi

    sysctl --system >>"$LOG_FILE" 2>&1 || true

    log_success "Файлы конфигурации удалены"

    if confirm "Удалить пакеты wireguard-tools / wireguard?" "n"; then
        DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
            wireguard wireguard-tools >>"$LOG_FILE" 2>&1 || \
            log_warn "apt-get purge wireguard завершился с ошибкой."
        DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq \
            >>"$LOG_FILE" 2>&1 || true
        log_success "Пакеты удалены"
    fi
}

main "$@"
