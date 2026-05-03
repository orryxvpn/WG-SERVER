#!/usr/bin/env bash
# ingress.sh — configure the ingress (RU) WireGuard client with policy routing.
#
# Sourced by setup.sh. Depends on common.sh, checks.sh, prompts.sh.
#
# The defining feature of this side is `Table = off` in wg0.conf: wg-quick
# will NOT install a default route through the tunnel. Routing decisions are
# made by an `ip rule` on fwmark=0x1 pointing at table `wgout`.

if [[ -n "${_WG_INGRESS_SOURCED:-}" ]]; then
    return 0
fi
_WG_INGRESS_SOURCED=1

# ingress_run <public_ip> <iface>
ingress_run() {
    local public_ip="$1"
    local iface="$2"

    {
        printf '\n'
        banner "INGRESS — параметры установки"
        printf '\n'
        printf '  Внешний IP:        %s\n' "$public_ip"
        printf '  Внешний интерфейс: %s\n' "$iface"
        # shellcheck disable=SC2153  # WG_INGRESS_IP defined in common.sh
        printf '  Туннельный IP:     %s/24\n' "$WG_INGRESS_IP"
        printf '  Endpoint (egress): будет запрошен ниже\n'
        printf '\n'
    }
    if ! confirm "Продолжить?"; then
        die "Прервано пользователем."
    fi

    log_step "Установка пакетов"
    install_packages wireguard wireguard-tools iproute2 iptables curl

    log_step "Настройка sysctl"
    ingress_write_sysctl

    log_step "Регистрация таблицы маршрутизации '${WG_TABLE_NAME}'"
    ingress_register_rt_table

    log_step "Генерация ключей INGRESS"
    ingress_generate_keys
    local ingress_priv ingress_pub
    ingress_priv="$(cat "$WG_DIR/ingress_private.key")"
    ingress_pub="$(cat "$WG_DIR/ingress_public.key")"

    {
        printf '\n'
        banner "Введите данные с EGRESS-сервера"
        printf '\n'
        printf 'Если ещё не запустили скрипт на egress — сначала сделайте это\n'
        printf '(на egress выберите роль 1), скопируйте оттуда EGRESS PUBLIC\n'
        printf 'KEY и PRESHARED KEY и вернитесь сюда.\n\n'
    }
    # Non-interactive bypass: each of the three values can be supplied via
    # environment variables. Useful when the user's terminal mangles paste
    # in a way the sanitizer can't catch — write the keys to a file and
    # source them, or pass with `WG_EGRESS_PUB=… sudo -E bash setup.sh`.
    local egress_pub egress_ip psk
    if [[ -n "${WG_EGRESS_PUB:-}" ]] && is_valid_wg_key "${WG_EGRESS_PUB}"; then
        egress_pub="${WG_EGRESS_PUB}"
        log_info "EGRESS PUBLIC KEY взят из WG_EGRESS_PUB"
    else
        prompt_wg_key egress_pub "EGRESS PUBLIC KEY:     "
    fi
    if [[ -n "${WG_EGRESS_IP:-}" ]] && is_valid_ipv4 "${WG_EGRESS_IP}"; then
        egress_ip="${WG_EGRESS_IP}"
        log_info "EGRESS IP взят из WG_EGRESS_IP"
    else
        prompt_ipv4 egress_ip "EGRESS IP (публичный): "
    fi
    if [[ -n "${WG_PSK:-}" ]] && is_valid_wg_key "${WG_PSK}"; then
        psk="${WG_PSK}"
        log_info "PRESHARED KEY взят из WG_PSK"
    else
        prompt_wg_key psk "PRESHARED KEY:         "
    fi

    # Persist PSK for completeness; wg0.conf already contains it inline.
    umask_secure
    printf '%s\n' "$psk" | atomic_write "$WG_DIR/wg.psk" 600

    log_step "Запись /etc/wireguard/wg0.conf"
    ingress_write_config "$ingress_priv" "$egress_pub" "$psk" "$egress_ip"

    log_step "Запуск wg-quick@${WG_IF}"
    ingress_start_service

    {
        printf '\n'
        banner "Скопируйте этот ключ и вставьте его на EGRESS"
        printf '\n'
        printf '%sINGRESS PUBLIC KEY:%s\n' "$C_BOLD" "$C_RESET"
        printf '  %s%s%s\n\n' "$C_GREEN" "$ingress_pub" "$C_RESET"
        printf 'Когда вставите его на EGRESS-сервере (там скрипт ждёт ввода),\n'
        printf 'возвращайтесь сюда — будут запущены проверки туннеля.\n\n'
    }
    pause "Нажмите ENTER когда вставите ключ на EGRESS-сервере..."

    log_step "Проверки"
    ingress_run_checks "$iface" "$egress_ip"

    ingress_finalize "$egress_ip"
}

# ingress_write_sysctl — drop sysctl settings for rp_filter / src_valid_mark.
# Note: ip_forward is NOT required on ingress because we don't forward — we
# originate connections (e.g. from xray) and route them via fwmark.
ingress_write_sysctl() {
    local body
    body="${WG_MARKER}
# Policy routing for WireGuard tunnel (ingress side)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
# Required for fwmark-based policy routing — kernel rejects packets with a
# non-default mark unless this is set. https://lwn.net/Articles/89139/
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.default.src_valid_mark = 1"
    write_sysctl "99-wg-ingress.conf" "$body"
}

# ingress_register_rt_table — add `<id> <name>` to /etc/iproute2/rt_tables
# unless already present. Idempotent.
ingress_register_rt_table() {
    local rt="/etc/iproute2/rt_tables"
    if [[ ! -f "$rt" ]]; then
        # Standard headers for a fresh file
        printf '#\n# reserved values\n#\n255\tlocal\n254\tmain\n253\tdefault\n0\tunspec\n' >"$rt"
    fi
    if ! awk -v id="$WG_TABLE_ID" -v name="$WG_TABLE_NAME" \
            '$1==id || $2==name {found=1} END{exit !found}' "$rt"; then
        printf '%s\t%s\n' "$WG_TABLE_ID" "$WG_TABLE_NAME" >>"$rt"
        log_info "Добавлено '${WG_TABLE_ID} ${WG_TABLE_NAME}' в $rt"
    else
        log_info "Таблица '${WG_TABLE_NAME}' уже зарегистрирована в $rt"
    fi
}

# ingress_generate_keys — create ingress_private.key + ingress_public.key.
ingress_generate_keys() {
    umask_secure
    mkdir -p "$WG_DIR"
    chmod 700 "$WG_DIR"
    if [[ ! -s "$WG_DIR/ingress_private.key" ]]; then
        wg genkey >"$WG_DIR/ingress_private.key"
    fi
    chmod 600 "$WG_DIR/ingress_private.key"
    wg pubkey <"$WG_DIR/ingress_private.key" >"$WG_DIR/ingress_public.key"
    chmod 644 "$WG_DIR/ingress_public.key"
    log_success "Ключи созданы в $WG_DIR"
}

# ingress_write_config <priv> <egress_pub> <psk> <egress_ip>
#
# The interface uses Table = off so wg-quick does not touch routing. We
# install our own policy routing via PostUp / PostDown:
#   - default route via wg0 in custom table $WG_TABLE_NAME
#   - ip rule that sends fwmark=$WG_FWMARK packets to that table
ingress_write_config() {
    local priv="$1"
    local egress_pub="$2"
    local psk="$3"
    local egress_ip="$4"
    local conf="$WG_DIR/wg0.conf"

    umask_secure
    mkdir -p "$WG_DIR"

    local body
    body="${WG_MARKER}
# Role: ingress
# Generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')
[Interface]
Address    = ${WG_INGRESS_IP}/24
PrivateKey = ${priv}
# Critical: Table = off prevents wg-quick from installing the AllowedIPs
# routes into the main table. We do our own policy routing below.
Table      = off

# Policy routing: fwmark ${WG_FWMARK} -> table ${WG_TABLE_NAME} -> default via %i
PostUp = ip route replace default dev %i table ${WG_TABLE_NAME}
PostUp = ip rule add fwmark ${WG_FWMARK} lookup ${WG_TABLE_NAME} priority 100 2>/dev/null || true

PostDown = ip rule del fwmark ${WG_FWMARK} lookup ${WG_TABLE_NAME} priority 100 2>/dev/null || true
PostDown = ip route del default dev %i table ${WG_TABLE_NAME} 2>/dev/null || true

[Peer]
# egress
PublicKey    = ${egress_pub}
PresharedKey = ${psk}
Endpoint     = ${egress_ip}:${WG_PORT}
AllowedIPs   = 0.0.0.0/0
PersistentKeepalive = 25
"
    printf '%s' "$body" | atomic_write "$conf" 600
    log_success "Записан $conf"
}

# ingress_start_service — enable and start (or restart) wg-quick@wg0.
ingress_start_service() {
    if systemctl is-active --quiet "wg-quick@${WG_IF}"; then
        systemctl restart "wg-quick@${WG_IF}" >>"$LOG_FILE" 2>&1 \
            || die "Не удалось перезапустить wg-quick@${WG_IF}. См. journalctl -u wg-quick@${WG_IF}"
    else
        systemctl enable "wg-quick@${WG_IF}" >>"$LOG_FILE" 2>&1 || true
        systemctl start "wg-quick@${WG_IF}" >>"$LOG_FILE" 2>&1 \
            || die "Не удалось запустить wg-quick@${WG_IF}. См. journalctl -u wg-quick@${WG_IF}"
    fi
    log_success "Сервис wg-quick@${WG_IF} запущен"
}

# ingress_run_checks <iface> <egress_ip>
# Run the verification battery. Each fail logs an error; we only die at the
# end if anything failed. NAT check (public IP via wg0) is the headline.
ingress_run_checks() {
    local iface="$1"
    local egress_ip="$2"
    local fail=0

    # 1. Handshake
    log_info "Жду handshake (до 60с)..."
    local hs
    local got_handshake=0
    local _i
    for _i in $(seq 1 60); do
        hs="$(wg show "$WG_IF" latest-handshakes 2>/dev/null \
                | awk '{print $2}' | head -1)"
        if [[ "${hs:-0}" =~ ^[0-9]+$ ]] && (( hs > 0 )); then
            got_handshake=1
            break
        fi
        sleep 1
    done
    if (( got_handshake )); then
        log_success "Handshake с egress установлен"
    else
        log_error "Handshake не получен за 60с — проверьте, что egress поднят и UDP ${WG_PORT} открыт"
        fail=1
    fi

    # 2. Ping the egress's tunnel IP
    if ping -c 3 -W 2 -I "$WG_IF" "$WG_EGRESS_IP" >/dev/null 2>&1; then
        log_success "Ping ${WG_EGRESS_IP} через ${WG_IF} OK"
    else
        log_error "Ping ${WG_EGRESS_IP} через ${WG_IF} не работает"
        fail=1
    fi

    # 3. Default route MUST NOT go through wg0 (Table = off check).
    if ip -4 route show default | grep -q "dev ${WG_IF}"; then
        log_error "Дефолтный маршрут идёт через ${WG_IF} — Table=off не сработал!"
        fail=1
    else
        log_success "Дефолтный маршрут НЕ изменился (Table = off работает)"
    fi

    # 4. Policy routing rule
    if ip rule show | grep -q "fwmark ${WG_FWMARK}.*lookup ${WG_TABLE_NAME}"; then
        log_success "ip rule fwmark ${WG_FWMARK} -> ${WG_TABLE_NAME} установлено"
    else
        log_error "Нет ip rule для fwmark ${WG_FWMARK} -> ${WG_TABLE_NAME}"
        fail=1
    fi

    # 5. Custom table has default via wg0
    if ip route show table "$WG_TABLE_NAME" 2>/dev/null \
            | grep -q "default dev ${WG_IF}"; then
        log_success "В таблице ${WG_TABLE_NAME} есть default dev ${WG_IF}"
    else
        log_error "В таблице ${WG_TABLE_NAME} нет default dev ${WG_IF}"
        fail=1
    fi

    # 6. With mark, egress
    if ip route get 1.1.1.1 mark "$WG_FWMARK" 2>/dev/null \
            | grep -q "dev ${WG_IF}"; then
        log_success "ip route get 1.1.1.1 mark ${WG_FWMARK} -> ${WG_IF}"
    else
        log_error "С меткой ${WG_FWMARK} маршрут НЕ идёт через ${WG_IF}"
        fail=1
    fi

    # 7. Without mark, main path
    if ip route get 1.1.1.1 2>/dev/null | grep -q "dev ${iface}"; then
        log_success "ip route get 1.1.1.1 (без mark) -> ${iface} (основной канал)"
    else
        log_warn "Основной маршрут не идёт через ${iface} — проверьте вручную."
    fi

    # 8. Headline NAT check: curl --interface wg0 must surface the egress IP.
    log_info "Проверяю NAT: curl --interface ${WG_IF} ifconfig.me ..."
    local seen_ip=""
    seen_ip="$(curl -4 -fsS --max-time 15 --interface "$WG_IF" \
                    https://ifconfig.me 2>/dev/null || true)"
    seen_ip="$(trim "$seen_ip")"
    if [[ -z "$seen_ip" ]]; then
        # Fallback provider
        seen_ip="$(curl -4 -fsS --max-time 15 --interface "$WG_IF" \
                        https://api.ipify.org 2>/dev/null || true)"
        seen_ip="$(trim "$seen_ip")"
    fi
    if [[ -z "$seen_ip" ]]; then
        log_error "Не удалось получить публичный IP через --interface ${WG_IF}."
        fail=1
    elif [[ "$seen_ip" == "$egress_ip" ]]; then
        log_success "NAT работает: трафик через ${WG_IF} уходит с IP ${seen_ip} (= EGRESS)"
    else
        log_error "Публичный IP через ${WG_IF} = ${seen_ip}, а ожидался ${egress_ip}."
        log_error "Это значит, что NAT/маршрутизация работают неправильно."
        fail=1
    fi

    if (( fail )); then
        die "Часть проверок не прошла. См. $LOG_FILE и journalctl -u wg-quick@${WG_IF}"
    fi
}

# ingress_finalize <egress_ip>
ingress_finalize() {
    local egress_ip="$1"
    {
        printf '\n'
        banner "✓ INGRESS настроен и проверен"
        printf '\n'
        printf 'Туннель работает корректно:\n'
        printf '  ✓ Handshake с egress установлен\n'
        printf '  ✓ Policy routing активен (fwmark=%s → %s)\n' "$WG_FWMARK" "$WG_IF"
        printf '  ✓ NAT работает: трафик через --interface %s уходит с IP %s\n' \
               "$WG_IF" "$egress_ip"
        printf '  ✓ Дефолтный маршрут НЕ изменился (Table = off работает)\n\n'
        printf 'Дальнейшие шаги (НЕ часть этого скрипта):\n'
        printf '  1. Установите Xray (если ещё не установлен)\n'
        printf '  2. Используйте config.json со страницей-инструкцией\n'
        printf '     для Reality (sockopt.mark = 1 в outbound)\n'
        printf '  3. Подключайте клиентов через Remnawave\n\n'
        printf 'Проверка цепочки после настройки Xray:\n'
        printf '  Подключитесь любым клиентом и проверьте свой IP — он\n'
        printf '  должен совпадать с %s.\n\n' "$egress_ip"
        printf 'Логи установки: %s\n\n' "$LOG_FILE"
    }
}
