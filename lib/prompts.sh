#!/usr/bin/env bash
# prompts.sh — interactive dialogs and key/IP prompts.
#
# Sourced by setup.sh. Depends on common.sh and checks.sh.

if [[ -n "${_WG_PROMPTS_SOURCED:-}" ]]; then
    return 0
fi
_WG_PROMPTS_SOURCED=1

# prompt_role — show the main menu and echo the chosen role to stdout.
# Possible values: egress | ingress | uninstall | quit
prompt_role() {
    local public_ip="${1:-?}"
    local iface="${2:-?}"
    local hostname="${3:-?}"
    local os="${4:-?}"
    {
        printf '\n'
        banner "WireGuard Tunnel Setup v${SCRIPT_VERSION}" \
               "INGRESS (RU) ↦ EGRESS"
        printf '\n'
        printf 'Этот скрипт настраивает один из двух серверов для схемы\n'
        printf 'RU-Reality-туннель → внешний выходной сервер.\n\n'
        printf 'Скрипт:\n'
        printf '  Версия:          %s%s%s\n' "$C_BOLD" "$SCRIPT_VERSION" "$C_RESET"
        if [[ -n "${WG_SOURCE_INFO:-}" ]]; then
            printf '  Источник:        %s\n' "$WG_SOURCE_INFO"
        fi
        printf '\nТекущий сервер:\n'
        printf '  Hostname:        %s\n' "$hostname"
        printf '  Public IPv4:     %s\n' "$public_ip"
        printf '  Default iface:   %s\n' "$iface"
        printf '  OS:              %s\n' "$os"
        printf '\nВыберите роль этого сервера:\n'
        printf '  1) EGRESS  (внешний, выходной — через него идёт трафик в интернет)\n'
        printf '  2) INGRESS (RU — на него подключаются клиенты, проксирует в туннель)\n'
        printf '  3) Удалить установку (uninstall)\n'
        printf '  4) Выход\n\n'
    } >&2

    local choice=""
    while true; do
        read_tty choice "Ваш выбор [1-4]: "
        choice="$(trim "$choice")"
        case "$choice" in
            1) printf 'egress';    return 0 ;;
            2) printf 'ingress';   return 0 ;;
            3) printf 'uninstall'; return 0 ;;
            4) printf 'quit';      return 0 ;;
            *) printf 'Неверный выбор. Введите число от 1 до 4.\n' >&2 ;;
        esac
    done
}

# prompt_wg_key <varname> <prompt>
# Read a WireGuard key from the user with retry-on-invalid.
#
# Sanitizes the raw input by stripping every byte outside the WG key alphabet
# (base64 + '='). This is a deliberate belt-and-suspenders defense — pasting
# in a terminal can introduce many invisible bytes (bracketed-paste markers,
# the bracketed-paste-mode toggle ESC[?2004h/l, NBSP from web copies, CR from
# Windows clipboards, ...). Stripping the alphabet leaves only the key.
prompt_wg_key() {
    local _varname="$1"
    local _prompt="$2"
    local _value=""
    local _clean=""
    while true; do
        read_tty _value "$_prompt"
        _clean="$(LC_ALL=C tr -cd 'A-Za-z0-9+/=' <<<"$_value")"
        if is_valid_wg_key "$_clean"; then
            printf -v "$_varname" '%s' "$_clean"
            return 0
        fi
        log_warn "Это не похоже на корректный WireGuard-ключ (нужно 44 base64-символа, заканчивается на '=')."
    done
}

# prompt_ipv4 <varname> <prompt>
# Same sanitization principle as prompt_wg_key: strip everything outside the
# IPv4 dotted-decimal alphabet before validating.
prompt_ipv4() {
    local _varname="$1"
    local _prompt="$2"
    local _value=""
    local _clean=""
    while true; do
        read_tty _value "$_prompt"
        _clean="$(LC_ALL=C tr -cd '0-9.' <<<"$_value")"
        if is_valid_ipv4 "$_clean"; then
            printf -v "$_varname" '%s' "$_clean"
            return 0
        fi
        log_warn "Это не похоже на IPv4-адрес. Пример: 198.51.100.7"
    done
}

# prompt_iface <varname> <prompt> <default>
prompt_iface() {
    local _varname="$1"
    local _prompt="$2"
    local _default="$3"
    local _value=""
    while true; do
        read_tty _value "${_prompt} [${_default}]: "
        _value="$(trim "$_value")"
        [[ -z "$_value" ]] && _value="$_default"
        if is_valid_iface "$_value"; then
            if ip link show "$_value" >/dev/null 2>&1; then
                printf -v "$_varname" '%s' "$_value"
                return 0
            fi
            log_warn "Интерфейс '$_value' не найден в системе. Введите ещё раз."
        else
            log_warn "Имя интерфейса невалидно."
        fi
    done
}

# prompt_uninstall_role — pick role for uninstall. Echos egress|ingress|both.
prompt_uninstall_role() {
    {
        printf '\n'
        banner "Удаление установки wg-tunnel-setup"
        printf '\nКакая роль настроена на этом сервере?\n'
        printf '  1) EGRESS\n'
        printf '  2) INGRESS\n'
        printf '  3) Не знаю / удалить всё\n'
        printf '  4) Отмена\n\n'
    } >&2
    local choice=""
    while true; do
        read_tty choice "Ваш выбор [1-4]: "
        choice="$(trim "$choice")"
        case "$choice" in
            1) printf 'egress';  return 0 ;;
            2) printf 'ingress'; return 0 ;;
            3) printf 'both';    return 0 ;;
            4) printf 'cancel';  return 0 ;;
            *) printf 'Неверный выбор.\n' >&2 ;;
        esac
    done
}
