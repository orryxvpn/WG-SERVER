#!/usr/bin/env bash
# checks.sh — preflight checks and input validators.
#
# Sourced by setup.sh. Functions only; no side effects on source.

if [[ -n "${_WG_CHECKS_SOURCED:-}" ]]; then
    return 0
fi
_WG_CHECKS_SOURCED=1

# require_command <cmd>
# Die with a friendly message if <cmd> is not on PATH.
require_command() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        die "Не найдена обязательная команда: $cmd"
    fi
}

# check_systemd — die if systemd is not the init system.
check_systemd() {
    if [[ ! -d /run/systemd/system ]]; then
        die "Этот скрипт требует systemd. На текущей системе systemd не запущен."
    fi
}

# check_apt — die if apt-get is missing.
check_apt() {
    if ! command -v apt-get >/dev/null 2>&1; then
        die "Не найден apt-get. Поддерживаются Debian/Ubuntu."
    fi
}

# check_internet — die if 1.1.1.1 is not reachable over IPv4 in 5s.
check_internet() {
    if ! curl -4 -fsS --max-time 5 -o /dev/null https://1.1.1.1 \
            && ! curl -4 -fsS --max-time 5 -o /dev/null http://1.1.1.1; then
        die "Нет доступа в интернет (curl -> 1.1.1.1). Проверьте сеть/файрвол."
    fi
}

# check_supported_os — populate OS_ID/OS_VERSION_ID and verify supported.
# Asks the user to confirm if the distro looks unfamiliar.
check_supported_os() {
    detect_os
    if [[ -z "$OS_ID" ]]; then
        log_warn "Не удалось определить ОС (нет /etc/os-release)."
        if ! confirm "Продолжить на свой риск?"; then
            die "Прервано пользователем."
        fi
        return 0
    fi
    case "$OS_ID" in
        ubuntu)
            local major="${OS_VERSION_ID%%.*}"
            if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 20 )); then
                log_info "ОС: $OS_PRETTY (поддерживается)"
                return 0
            fi
            log_warn "Ubuntu $OS_VERSION_ID может не поддерживаться (нужно 20.04+)."
            ;;
        debian)
            local major="${OS_VERSION_ID%%.*}"
            if [[ "$major" =~ ^[0-9]+$ ]] && (( major >= 11 )); then
                log_info "ОС: $OS_PRETTY (поддерживается)"
                return 0
            fi
            log_warn "Debian $OS_VERSION_ID может не поддерживаться (нужно 11+)."
            ;;
        *)
            log_warn "Неизвестная ОС: $OS_PRETTY (id=$OS_ID)."
            ;;
    esac
    if ! confirm "Продолжить на свой риск?"; then
        die "Прервано пользователем."
    fi
}

# check_existing_install — if a previous wg-tunnel-setup install is detected,
# offer to wipe and reinstall. Returns 0 if we should continue, 1 if user
# declined (caller should exit).
check_existing_install() {
    local conf="$WG_DIR/wg0.conf"
    if [[ -f "$conf" ]] && grep -q "wg-tunnel-setup" "$conf" 2>/dev/null; then
        log_warn "Найдена существующая установка wg-tunnel-setup в $conf."
        if confirm "Переустановить (стереть и заново)?"; then
            return 0
        fi
        log_info "Установка отменена пользователем."
        return 1
    fi
    if [[ -f "$conf" ]]; then
        log_warn "Найден $conf, но без маркера wg-tunnel-setup."
        log_warn "Если он создан вручную, скрипт может его перезаписать."
        if ! confirm "Перезаписать $conf?"; then
            return 1
        fi
    fi
    return 0
}

# ------------------------------------------------------------------------------
# Validators (all return 0 on valid, 1 otherwise)
# ------------------------------------------------------------------------------

# is_valid_wg_key <string>
# WireGuard keys are 32 raw bytes encoded in base64 = 44 characters ending in
# a single '=' padding character.
is_valid_wg_key() {
    local k="$1"
    [[ "$k" =~ ^[A-Za-z0-9+/]{43}=$ ]]
}

# is_valid_ipv4 <string>
is_valid_ipv4() {
    local ip="$1"
    [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
    local o
    for o in "${BASH_REMATCH[@]:1:4}"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

# is_valid_iface <string>
is_valid_iface() {
    local i="$1"
    [[ "$i" =~ ^[A-Za-z0-9._-]+$ ]] && [[ ${#i} -le 15 ]]
}
