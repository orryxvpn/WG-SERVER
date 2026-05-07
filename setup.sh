#!/usr/bin/env bash
# setup.sh — interactive INGRESS↦EGRESS tunnel installer.
#
# Supports three transport protocols:
#   1. WireGuard               — kernel tunnel, simplest
#   2. Hysteria 2 (sing-box)   — UDP/QUIC, fast, FEC built in
#   3. VLESS+Reality+Vision    — TCP/TLS, max stealth (looks like HTTPS)
#
# Usage:
#   sudo bash setup.sh                              # local checkout
#   curl -fsSL <pinned-url>/setup.sh | sudo bash    # one-liner

set -euo pipefail

# ------------------------------------------------------------------------------
# Constants — keep these in sync with lib/common.sh.
# ------------------------------------------------------------------------------
SCRIPT_VERSION="1.1.0"
REPO_SLUG="${WG_REPO_SLUG:-orryxvpn/wg-server}"
REPO_REF="${WG_REPO_REF:-v${SCRIPT_VERSION}}"
LIB_FILES=(
    "common.sh" "checks.sh" "prompts.sh"
    "egress.sh" "ingress.sh"
    "singbox.sh" "hy2.sh" "vless.sh"
)
# shellcheck disable=SC2034  # consumed by lib/prompts.sh
WG_SOURCE_INFO=""

LOG_FILE="${LOG_FILE:-/var/log/wg-tunnel-setup.log}"
LIB_DIR=""
TMP_LIB_DIR=""

# ------------------------------------------------------------------------------
# Bootstrap helpers (must be self-sufficient — common.sh isn't loaded yet).
# ------------------------------------------------------------------------------
_bootstrap_die() {
    if [[ -t 2 ]]; then
        printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2
    else
        printf '[ERROR] %s\n' "$*" >&2
    fi
    exit 1
}

script_dir() {
    local src="${BASH_SOURCE[0]:-}"
    if [[ -n "$src" && -f "$src" ]]; then
        ( cd -- "$(dirname -- "$src")" && pwd )
        return 0
    fi
    printf ''
}

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
        # shellcheck disable=SC2034
        WG_SOURCE_INFO="downloaded from ref=${REPO_REF}"
    else
        # shellcheck disable=SC2034
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

_bootstrap_download_libs() {
    if ! command -v curl >/dev/null 2>&1; then
        _bootstrap_die "Не найден curl. Установите: apt-get install -y curl"
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

_bootstrap_cleanup() {
    if [[ -n "${TMP_LIB_DIR:-}" && -d "$TMP_LIB_DIR" ]]; then
        rm -rf -- "$TMP_LIB_DIR"
    fi
}

# ------------------------------------------------------------------------------
# Error / exit handling
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
        if systemctl is-failed --quiet "wg-quick@${WG_IF}" 2>/dev/null; then
            log_warn "wg-quick@${WG_IF} в состоянии failed — см. journalctl -u wg-quick@${WG_IF}"
        fi
        if systemctl is-failed --quiet "${SB_SERVICE:-sing-box}" 2>/dev/null; then
            log_warn "sing-box в состоянии failed — см. journalctl -u ${SB_SERVICE:-sing-box}"
        fi
    fi
    _bootstrap_cleanup
}

# ------------------------------------------------------------------------------
# Existing-install detection
# ------------------------------------------------------------------------------

# detect_existing_proto — print "wg" | "hy2" | "vless" | "" depending on
# what looks already configured. Used to offer reinstall.
detect_existing_proto() {
    if [[ -f "$WG_DIR/wg0.conf" ]] && grep -q "wg-tunnel-setup" "$WG_DIR/wg0.conf" 2>/dev/null; then
        printf 'wg'; return 0
    fi
    if [[ -f "$SB_CONFIG" ]] && grep -q "wg-tunnel-setup" "$SB_CONFIG" 2>/dev/null; then
        if grep -q '"type":[[:space:]]*"hysteria2"' "$SB_CONFIG"; then
            printf 'hy2'; return 0
        fi
        if grep -q '"type":[[:space:]]*"vless"' "$SB_CONFIG"; then
            printf 'vless'; return 0
        fi
    fi
    printf ''
}

# wipe_install <proto>
# Hard-remove a previous install. <proto> ∈ {wg, hy2, vless, all}.
wipe_install() {
    local proto="$1"
    log_step "Удаление установки (proto=${proto})"
    if [[ "$proto" == "wg" || "$proto" == "all" ]]; then
        if systemctl list-unit-files 2>/dev/null \
                | grep -q "^wg-quick@${WG_IF}\.service"; then
            systemctl disable --now "wg-quick@${WG_IF}" >>"$LOG_FILE" 2>&1 || true
        fi
        rm -f "$WG_DIR/wg0.conf"
        rm -f "$WG_DIR/egress_private.key" "$WG_DIR/egress_public.key"
        rm -f "$WG_DIR/ingress_private.key" "$WG_DIR/ingress_public.key"
        rm -f "$WG_DIR/wg.psk"
        rm -f /etc/sysctl.d/99-wg-egress.conf /etc/sysctl.d/99-wg-ingress.conf
        ip rule del fwmark "$WG_FWMARK" lookup "$WG_TABLE_NAME" priority 100 \
            >/dev/null 2>&1 || true
        ip route flush table "$WG_TABLE_NAME" >/dev/null 2>&1 || true
        if [[ -f /etc/iproute2/rt_tables ]]; then
            sed -i.bak \
                -e "/^${WG_TABLE_ID}[[:space:]]\\+${WG_TABLE_NAME}\\b/d" \
                /etc/iproute2/rt_tables
            rm -f /etc/iproute2/rt_tables.bak
        fi
    fi
    if [[ "$proto" == "hy2" || "$proto" == "vless" || "$proto" == "all" ]]; then
        # ingress=true cleans both the routing units and rt_tables; for an
        # egress-only install the routing units don't exist and that's fine.
        sb_uninstall_files "ingress"
    fi
    sysctl --system >>"$LOG_FILE" 2>&1 || true
    log_success "Файлы конфигурации удалены"
}

# offer_uninstall_packages <proto>
offer_uninstall_packages() {
    local proto="$1"
    if [[ "$proto" == "wg" || "$proto" == "all" ]]; then
        if confirm "Удалить пакеты wireguard / wireguard-tools?" "n"; then
            DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
                wireguard wireguard-tools >>"$LOG_FILE" 2>&1 \
                || log_warn "apt-get purge wireguard завершился с ошибкой."
        fi
    fi
    if [[ "$proto" == "hy2" || "$proto" == "vless" || "$proto" == "all" ]]; then
        if confirm "Удалить пакет sing-box?" "n"; then
            DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq \
                sing-box >>"$LOG_FILE" 2>&1 \
                || log_warn "apt-get purge sing-box завершился с ошибкой."
        fi
    fi
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y -qq \
        >>"$LOG_FILE" 2>&1 || true
}

# ------------------------------------------------------------------------------
# Per-(protocol, role) dispatch
# ------------------------------------------------------------------------------

# run_protocol_role <protocol> <role> <public_ip> <iface>
run_protocol_role() {
    local proto="$1" role="$2" ip="$3" iface="$4"
    local existing
    existing="$(detect_existing_proto)"
    if [[ -n "$existing" ]]; then
        log_warn "Найдена существующая установка (proto=${existing})."
        if confirm "Стереть и поставить заново?" "n"; then
            wipe_install "$existing"
        else
            log_info "Установка отменена."
            exit 0
        fi
    fi
    case "${proto}_${role}" in
        wg_egress)     egress_run        "$ip" "$iface" ;;
        wg_ingress)    ingress_run       "$ip" "$iface" ;;
        hy2_egress)    hy2_egress_run    "$ip" "$iface" ;;
        hy2_ingress)   hy2_ingress_run   "$ip" "$iface" ;;
        vless_egress)  vless_egress_run  "$ip" "$iface" ;;
        vless_ingress) vless_ingress_run "$ip" "$iface" ;;
        *)             die "Не реализовано: ${proto}/${role}" ;;
    esac
}

# ------------------------------------------------------------------------------
# Main
# ------------------------------------------------------------------------------
main() {
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

    local default_iface public_ip hostname_str os_str
    default_iface="$(detect_default_iface || true)"
    [[ -z "$default_iface" ]] && default_iface="(не определено)"
    public_ip="$(detect_public_ipv4 || true)"
    [[ -z "$public_ip" ]] && public_ip="(не определено)"
    hostname_str="$(hostname 2>/dev/null || echo unknown)"
    os_str="${OS_PRETTY:-${OS_ID:-unknown}}"

    while true; do
        local proto
        proto="$(prompt_protocol "$public_ip" "$default_iface" "$hostname_str" "$os_str")"
        _log_to_file "INFO" "proto=$proto"

        case "$proto" in
            wg|hy2|vless)
                local label
                case "$proto" in
                    wg)    label="WireGuard" ;;
                    hy2)   label="Hysteria 2" ;;
                    vless) label="VLESS+Reality+Vision" ;;
                esac
                local role
                role="$(prompt_role_only "$label")"
                _log_to_file "INFO" "role=$role"
                if [[ "$role" == "back" ]]; then
                    continue
                fi
                run_protocol_role "$proto" "$role" "$public_ip" "$default_iface"
                return 0
                ;;
            uninstall)
                local existing
                existing="$(detect_existing_proto)"
                if [[ -z "$existing" ]]; then
                    log_warn "Установка wg-tunnel-setup не обнаружена."
                    if ! confirm "Всё равно прогнать удаление (на всякий случай)?" "n"; then
                        return 0
                    fi
                    existing="all"
                fi
                wipe_install "$existing"
                offer_uninstall_packages "$existing"
                log_success "Установка удалена. Логи: $LOG_FILE"
                return 0
                ;;
            quit)
                log_info "Выход."
                return 0
                ;;
            *)
                die "Неизвестный выбор: $proto"
                ;;
        esac
    done
}

main "$@"
