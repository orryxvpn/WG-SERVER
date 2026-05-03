#!/usr/bin/env bash
# egress.sh — configure the egress (outbound) WireGuard server.
#
# Sourced by setup.sh. Depends on common.sh, checks.sh, prompts.sh.

if [[ -n "${_WG_EGRESS_SOURCED:-}" ]]; then
    return 0
fi
_WG_EGRESS_SOURCED=1

# egress_run <public_ip> <iface>
# Top-level driver for egress role.
egress_run() {
    local public_ip="$1"
    local iface="$2"

    local confirm_iface="$iface"
    prompt_iface confirm_iface "Внешний (uplink) интерфейс" "$iface"
    iface="$confirm_iface"

    {
        printf '\n'
        banner "EGRESS — параметры установки"
        printf '\n'
        printf '  Внешний IP:        %s\n' "$public_ip"
        printf '  Внешний интерфейс: %s\n' "$iface"
        printf '  Туннельный IP:     %s/24\n' "$WG_EGRESS_IP"
        printf '  Listen port:       UDP %s\n' "$WG_PORT"
        printf '  Allowed peer:      %s/32 (ingress)\n' "$WG_INGRESS_IP"
        printf '\n'
    }
    if ! confirm "Продолжить?"; then
        die "Прервано пользователем."
    fi

    log_step "Установка пакетов"
    install_packages wireguard wireguard-tools iproute2 iptables curl \
                     iptables-persistent

    log_step "Настройка sysctl"
    egress_write_sysctl

    log_step "Генерация ключей WireGuard"
    egress_generate_keys
    local egress_pub egress_priv psk
    egress_priv="$(cat "$WG_DIR/egress_private.key")"
    egress_pub="$(cat "$WG_DIR/egress_public.key")"
    psk="$(cat "$WG_DIR/wg.psk")"

    egress_show_keys "$egress_pub" "$psk"

    local ingress_pub=""
    if [[ -n "${WG_INGRESS_PUB:-}" ]] && is_valid_wg_key "${WG_INGRESS_PUB}"; then
        ingress_pub="${WG_INGRESS_PUB}"
        log_info "INGRESS PUBLIC KEY взят из WG_INGRESS_PUB"
    else
        {
            printf '\n'
            banner "ШАГ 2 ИЗ 2: ввод ключа от INGRESS"
            printf '\n'
            printf 'Запустите скрипт на INGRESS-сервере (выберите роль 2),\n'
            printf 'дождитесь там вывода INGRESS PUBLIC KEY и вставьте его сюда.\n\n'
        }
        prompt_wg_key ingress_pub "INGRESS PUBLIC KEY: "
    fi

    log_step "Запись /etc/wireguard/wg0.conf"
    egress_write_config "$iface" "$egress_priv" "$ingress_pub" "$psk"

    log_step "Запуск wg-quick@${WG_IF}"
    egress_start_service

    log_step "Проверки"
    egress_run_checks "$iface"

    egress_finalize
}

# egress_write_sysctl — drop sysctl settings for forwarding/rp_filter.
egress_write_sysctl() {
    local body
    body="${WG_MARKER}
# Forwarding for WireGuard tunnel (egress side)
net.ipv4.ip_forward = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2"
    write_sysctl "99-wg-egress.conf" "$body"
}

# egress_generate_keys — create private/public/psk under $WG_DIR with mode 600.
# No private key material reaches the log.
egress_generate_keys() {
    umask_secure
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    if [[ ! -s "$WG_DIR/egress_private.key" ]]; then
        wg genkey >"$WG_DIR/egress_private.key"
    fi
    chmod 600 "$WG_DIR/egress_private.key"
    wg pubkey <"$WG_DIR/egress_private.key" >"$WG_DIR/egress_public.key"
    chmod 644 "$WG_DIR/egress_public.key"
    if [[ ! -s "$WG_DIR/wg.psk" ]]; then
        wg genpsk >"$WG_DIR/wg.psk"
    fi
    chmod 600 "$WG_DIR/wg.psk"
    log_success "Ключи созданы в $WG_DIR"
}

# egress_show_keys <pubkey> <psk>
egress_show_keys() {
    local pub="$1"
    local psk="$2"
    {
        printf '\n'
        banner "ШАГ 1 ИЗ 2: ключи для INGRESS-сервера"
        printf '\n'
        printf 'Скопируйте эти два значения. Они понадобятся при запуске\n'
        printf 'скрипта на INGRESS (RU) сервере.\n\n'
        printf '%sEGRESS PUBLIC KEY:%s\n' "$C_BOLD" "$C_RESET"
        printf '  %s%s%s\n\n' "$C_GREEN" "$pub" "$C_RESET"
        printf '%sPRESHARED KEY:%s   %s(не передавайте никому кроме INGRESS-сервера)%s\n' \
               "$C_BOLD" "$C_RESET" "$C_YELLOW" "$C_RESET"
        printf '  %s%s%s\n\n' "$C_GREEN" "$psk" "$C_RESET"
    }
    pause "Нажмите ENTER когда скопируете оба ключа..."
}

# egress_write_config <iface> <priv> <ingress_pub> <psk>
egress_write_config() {
    local iface="$1"
    local priv="$2"
    local ingress_pub="$3"
    local psk="$4"
    local conf="$WG_DIR/wg0.conf"

    umask_secure
    mkdir -p "$WG_DIR"

    # Build the config in a heredoc — variables expand inline so we never need
    # `\$(cat ...)` shell substitution at wg-quick run-time.
    local body
    body="${WG_MARKER}
# Role: egress
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
[Interface]
Address    = ${WG_EGRESS_IP}/24
ListenPort = ${WG_PORT}
PrivateKey = ${priv}

# NAT + forwarding rules for traffic from the tunnel out to the internet.
PostUp   = iptables -t nat -C POSTROUTING -s ${WG_NET_CIDR} -o ${iface} -j MASQUERADE 2>/dev/null || iptables -t nat -A POSTROUTING -s ${WG_NET_CIDR} -o ${iface} -j MASQUERADE
PostUp   = iptables -C FORWARD -i %i -o ${iface} -j ACCEPT 2>/dev/null || iptables -A FORWARD -i %i -o ${iface} -j ACCEPT
PostUp   = iptables -C FORWARD -i ${iface} -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i ${iface} -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT
PostDown = iptables -t nat -D POSTROUTING -s ${WG_NET_CIDR} -o ${iface} -j MASQUERADE 2>/dev/null || true
PostDown = iptables -D FORWARD -i %i -o ${iface} -j ACCEPT 2>/dev/null || true
PostDown = iptables -D FORWARD -i ${iface} -o %i -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

[Peer]
# ingress (RU)
PublicKey    = ${ingress_pub}
PresharedKey = ${psk}
AllowedIPs   = ${WG_INGRESS_IP}/32
"
    printf '%s' "$body" | atomic_write "$conf" 600
    log_success "Записан $conf"
}

# egress_start_service — enable and start wg-quick@wg0.
egress_start_service() {
    # If it's already up, restart so the fresh config takes effect.
    if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
        systemctl restart "wg-quick@${WG_IF}" >>"$LOG_FILE" 2>&1 || \
            die "Не удалось перезапустить wg-quick@${WG_IF}. См. journalctl -u wg-quick@${WG_IF}"
    else
        systemctl enable "wg-quick@${WG_IF}" >>"$LOG_FILE" 2>&1 || true
        systemctl start "wg-quick@${WG_IF}" >>"$LOG_FILE" 2>&1 || \
            die "Не удалось запустить wg-quick@${WG_IF}. См. journalctl -u wg-quick@${WG_IF}"
    fi
    # Persist netfilter rules so they survive reboots (iptables-persistent).
    if command -v netfilter-persistent >/dev/null 2>&1; then
        netfilter-persistent save >>"$LOG_FILE" 2>&1 || \
            log_warn "netfilter-persistent save завершился с ошибкой."
    fi
    log_success "Сервис wg-quick@${WG_IF} запущен"
}

# egress_run_checks <iface>
egress_run_checks() {
    local iface="$1"
    local fail=0

    if wg show "$WG_IF" >/dev/null 2>&1; then
        log_success "wg show ${WG_IF}: интерфейс активен"
    else
        log_error "wg show ${WG_IF} не вернул данные"
        fail=1
    fi

    if ip -4 addr show "$WG_IF" 2>/dev/null | grep -q "${WG_EGRESS_IP}"; then
        log_success "На ${WG_IF} назначен ${WG_EGRESS_IP}/24"
    else
        log_error "Адрес ${WG_EGRESS_IP} не найден на ${WG_IF}"
        fail=1
    fi

    if iptables -t nat -S POSTROUTING 2>/dev/null \
            | grep -q -- "-s ${WG_NET_CIDR}.*-o ${iface}.*MASQUERADE"; then
        log_success "Правило MASQUERADE для ${WG_NET_CIDR} -> ${iface} установлено"
    else
        log_error "Не найдено правило MASQUERADE в iptables -t nat"
        fail=1
    fi

    if ss -ulnp 2>/dev/null | grep -q ":${WG_PORT}\b"; then
        log_success "UDP ${WG_PORT} прослушивается"
    else
        log_warn "UDP ${WG_PORT} не виден через ss; это может быть нормально (ядерный сокет)."
    fi

    log_info "Жду handshake от ingress (до 60с)... handshake появится только после настройки INGRESS."
    local i hs
    for i in $(seq 1 60); do
        hs="$(wg show "$WG_IF" latest-handshakes 2>/dev/null | awk '{print $2}' | head -1)"
        if [[ "${hs:-0}" =~ ^[0-9]+$ ]] && (( hs > 0 )); then
            log_success "Handshake получен (это значит, ingress уже поднят)."
            break
        fi
        sleep 1
        # Don't fail if no handshake yet — ingress may not be configured.
        [[ $i -eq 60 ]] && log_info "Handshake пока нет — это нормально, если INGRESS ещё не настроен."
    done

    if (( fail )); then
        die "Часть проверок не прошла. См. $LOG_FILE и journalctl -u wg-quick@${WG_IF}"
    fi
}

# egress_finalize — last bits of UI on success.
egress_finalize() {
    {
        printf '\n'
        banner "✓ EGRESS настроен"
        printf '\n'
        printf 'Дальнейшие шаги:\n'
        printf '  1. Если ещё не сделали — запустите этот скрипт на INGRESS\n'
        printf '  2. После настройки INGRESS проверьте handshake:\n'
        printf '       wg show %s\n' "$WG_IF"
        printf '     В строке "latest handshake" должно быть свежее значение.\n\n'
        printf 'Полезные команды:\n'
        printf '  systemctl status wg-quick@%s\n' "$WG_IF"
        printf '  wg show %s\n' "$WG_IF"
        printf '  journalctl -u wg-quick@%s -f\n\n' "$WG_IF"
        printf 'Логи установки: %s\n\n' "$LOG_FILE"
    }
}
