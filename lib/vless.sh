#!/usr/bin/env bash
# vless.sh — VLESS + Reality + Vision driver. TCP-based stealth tunnel
# implemented on top of sing-box.
#
# EGRESS: VLESS+Reality+Vision server. Reality forwards mismatched handshakes
# to a real public host (default www.cloudflare.com:443) so a passive observer
# can't tell us apart from real traffic to that host.
# INGRESS: VLESS+Reality+Vision client + sing-box TUN, fwmark 0x1 -> singtun0.

if [[ -n "${_WG_VLESS_SOURCED:-}" ]]; then
    return 0
fi
_WG_VLESS_SOURCED=1

# ------------------------------------------------------------------------------
# EGRESS
# ------------------------------------------------------------------------------

# vless_egress_run <public_ip> <iface_unused>
vless_egress_run() {
    local public_ip="$1"
    local port="${VLESS_PORT:-${VLESS_PORT_DEFAULT}}"
    local dest="${VLESS_DEST:-${VLESS_DEST_DEFAULT}}"
    local sni="${VLESS_SNI:-${VLESS_SNI_DEFAULT}}"

    {
        printf '\n'
        banner "EGRESS (VLESS+Reality+Vision) — параметры установки"
        printf '\n'
        printf '  Внешний IP:           %s\n' "$public_ip"
        printf '  Listen port:          TCP %s\n' "$port"
        printf '  Reality dest:         %s\n' "$dest"
        printf '  Reality SNI:          %s\n' "$sni"
        printf '\n'
    }
    if ! confirm "Продолжить?"; then
        die "Прервано пользователем."
    fi

    log_step "Установка sing-box"
    sb_install

    log_step "Генерация ключей Reality + UUID + short_id"
    sb_gen_reality_keypair_to "$SB_DIR"
    local reality_priv reality_pub uuid short_id
    reality_priv="$(<"$SB_DIR/reality_private.key")"
    reality_pub="$(<"$SB_DIR/reality_public.key")"
    uuid="$(sb_gen_uuid)"
    short_id="$(sb_gen_short_id)"
    umask_secure
    printf '%s\n' "$uuid" >"$SB_DIR/vless.uuid"
    chmod 600 "$SB_DIR/vless.uuid"

    log_step "Запись /etc/sing-box/config.json"
    vless_write_egress_config "$port" "$uuid" "$reality_priv" "$short_id" "$dest" "$sni"

    log_step "Запуск sing-box"
    sb_start

    vless_show_egress_bundle "$public_ip" "$port" "$uuid" "$reality_pub" "$short_id" "$sni"
    vless_egress_run_checks "$port"
    vless_egress_finalize
}

# vless_write_egress_config <port> <uuid> <reality_priv> <short_id> <dest> <sni>
vless_write_egress_config() {
    local port="$1" uuid="$2" priv="$3" short_id="$4" dest="$5" sni="$6"
    local dest_host="${dest%%:*}"
    local dest_port="${dest##*:}"
    local body
    body="${SB_MARKER}
// Role: vless egress (server)
{
  \"log\": { \"level\": \"warn\", \"timestamp\": true },
  \"inbounds\": [
    {
      \"type\": \"vless\",
      \"tag\": \"vless-in\",
      \"listen\": \"::\",
      \"listen_port\": ${port},
      \"users\": [{ \"uuid\": \"${uuid}\", \"flow\": \"xtls-rprx-vision\" }],
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${sni}\",
        \"reality\": {
          \"enabled\": true,
          \"handshake\": {
            \"server\": \"${dest_host}\",
            \"server_port\": ${dest_port}
          },
          \"private_key\": \"${priv}\",
          \"short_id\": [\"${short_id}\"]
        }
      }
    }
  ],
  \"outbounds\": [
    { \"type\": \"direct\", \"tag\": \"direct\" }
  ]
}"
    sb_write_config "$body"
}

# vless_show_egress_bundle <ip> <port> <uuid> <pub> <short_id> <sni>
vless_show_egress_bundle() {
    local ip="$1" port="$2" uuid="$3" pub="$4" short_id="$5" sni="$6"
    local bundle
    bundle="$(sb_encode_bundle \
        "proto=vless" \
        "ip=${ip}" \
        "port=${port}" \
        "uuid=${uuid}" \
        "pub=${pub}" \
        "sid=${short_id}" \
        "sni=${sni}")"
    {
        printf '\n'
        banner "ШАГ 1 ИЗ 2: данные для INGRESS-сервера"
        printf '\n'
        printf 'Скопируйте %sодну строку%s ниже целиком — это весь набор\n' "$C_BOLD" "$C_RESET"
        printf 'значений в одном base64-блоке. На INGRESS подставите его\n'
        printf 'в переменную VLESS_BUNDLE и больше ничего вводить руками не нужно.\n\n'
        printf '%sVLESS_BUNDLE:%s\n' "$C_BOLD" "$C_RESET"
        printf '  %s%s%s\n\n' "$C_GREEN" "$bundle" "$C_RESET"
        printf '%sРасшифровка (для глаза):%s\n' "$C_BOLD" "$C_RESET"
        printf '  ip:        %s\n' "$ip"
        printf '  port:      %s (TCP)\n' "$port"
        printf '  uuid:      %s\n' "$uuid"
        printf '  pub_key:   %s\n' "$pub"
        printf '  short_id:  %s\n' "$short_id"
        printf '  sni:       %s\n' "$sni"
        printf '\nРекомендуемый запуск на INGRESS:\n'
        printf '  sudo -E VLESS_BUNDLE=%q WG_REPO_REF=main bash setup.sh\n\n' "$bundle"
    }
    pause "Нажмите ENTER когда скопируете VLESS_BUNDLE..."
}

# vless_egress_run_checks <port>
vless_egress_run_checks() {
    local port="$1"
    if ! systemctl is-active --quiet "$SB_SERVICE"; then
        die "sing-box не запущен. См. journalctl -u ${SB_SERVICE}"
    fi
    log_success "sing-box активен"
    if ss -tlnp 2>/dev/null | grep -qE ":${port}\\b"; then
        log_success "TCP ${port} прослушивается"
    else
        log_warn "TCP ${port} не виден через ss (не критично; см. journalctl)"
    fi
}

vless_egress_finalize() {
    {
        printf '\n'
        banner "✓ EGRESS (VLESS+Reality+Vision) настроен"
        printf '\n'
        printf 'Дальнейшие шаги:\n'
        printf '  1. Скопированный VLESS_BUNDLE передайте на INGRESS-сервер.\n'
        printf '  2. На INGRESS запустите setup.sh, выберите VLESS+Reality + INGRESS\n'
        printf '     или сразу подставьте VLESS_BUNDLE через переменную.\n\n'
        printf 'Полезные команды:\n'
        printf '  systemctl status %s\n' "$SB_SERVICE"
        printf '  journalctl -u %s -f\n\n' "$SB_SERVICE"
        printf 'Логи установки: %s\n\n' "$LOG_FILE"
    }
}

# ------------------------------------------------------------------------------
# INGRESS
# ------------------------------------------------------------------------------

# vless_ingress_run <public_ip> <iface_unused>
vless_ingress_run() {
    local public_ip="$1"

    local egress_ip="" port="" uuid="" pub="" short_id="" sni=""
    if [[ -n "${VLESS_BUNDLE:-}" ]]; then
        log_info "Распаковка VLESS_BUNDLE"
        sb_decode_bundle_to_var "$VLESS_BUNDLE" "ip"   egress_ip || die "Битый VLESS_BUNDLE: нет 'ip'"
        sb_decode_bundle_to_var "$VLESS_BUNDLE" "port" port      || die "Битый VLESS_BUNDLE: нет 'port'"
        sb_decode_bundle_to_var "$VLESS_BUNDLE" "uuid" uuid      || die "Битый VLESS_BUNDLE: нет 'uuid'"
        sb_decode_bundle_to_var "$VLESS_BUNDLE" "pub"  pub       || die "Битый VLESS_BUNDLE: нет 'pub'"
        sb_decode_bundle_to_var "$VLESS_BUNDLE" "sid"  short_id  || die "Битый VLESS_BUNDLE: нет 'sid'"
        sb_decode_bundle_to_var "$VLESS_BUNDLE" "sni"  sni       || sni="${VLESS_SNI:-${VLESS_SNI_DEFAULT}}"
        is_valid_ipv4 "$egress_ip" || die "VLESS_BUNDLE.ip не IPv4: $egress_ip"
        is_valid_uuid "$uuid"      || die "VLESS_BUNDLE.uuid невалидный: $uuid"
        log_info "EGRESS endpoint=${egress_ip}:${port}, sni=${sni}"
    else
        if [[ -n "${VLESS_EGRESS_IP:-}" ]] && is_valid_ipv4 "${VLESS_EGRESS_IP}"; then
            egress_ip="${VLESS_EGRESS_IP}"
        else
            prompt_ipv4 egress_ip "EGRESS IP (публичный): "
        fi
        port="${VLESS_PORT:-${VLESS_PORT_DEFAULT}}"
        if [[ -n "${VLESS_UUID:-}" ]] && is_valid_uuid "${VLESS_UUID}"; then
            uuid="${VLESS_UUID}"
        else
            log_warn "VLESS_UUID не задана. Лучше использовать VLESS_BUNDLE."
            read_tty uuid "VLESS UUID (с egress): "
            is_valid_uuid "$uuid" || die "Невалидный UUID."
        fi
        if [[ -n "${VLESS_PUBLIC_KEY:-}" ]]; then
            pub="${VLESS_PUBLIC_KEY}"
        else
            read_tty pub "Reality PUBLIC KEY (с egress): "
            [[ -n "$pub" ]] || die "Пустой Reality public key."
        fi
        if [[ -n "${VLESS_SHORT_ID:-}" ]]; then
            short_id="${VLESS_SHORT_ID}"
        else
            read_tty short_id "Reality SHORT_ID (hex, с egress): "
            [[ -n "$short_id" ]] || die "Пустой short_id."
        fi
        sni="${VLESS_SNI:-${VLESS_SNI_DEFAULT}}"
    fi

    {
        printf '\n'
        banner "INGRESS (VLESS+Reality+Vision) — параметры установки"
        printf '\n'
        printf '  Внешний IP (этот сервер):  %s\n' "$public_ip"
        printf '  EGRESS endpoint:           %s:%s (TCP)\n' "$egress_ip" "$port"
        printf '  Reality SNI:               %s\n' "$sni"
        printf '  TUN-интерфейс:             %s (%s)\n' "$SB_TUN_IFACE" "$SB_TUN_ADDR"
        printf '  Policy routing:            fwmark %s -> table %s\n' "$SB_FWMARK" "$SB_TABLE_NAME"
        printf '\n'
    }
    if ! confirm "Продолжить?"; then
        die "Прервано пользователем."
    fi

    log_step "Установка sing-box"
    sb_install

    log_step "Настройка sysctl и таблицы маршрутизации"
    sb_write_ingress_sysctl
    sb_register_rt_table

    log_step "Запись /etc/sing-box/config.json"
    vless_write_ingress_config "$egress_ip" "$port" "$uuid" "$pub" "$short_id" "$sni"

    log_step "Запуск sing-box"
    sb_start

    log_step "Установка systemd-юнита для policy routing"
    sb_install_ingress_routing_units

    log_step "Проверки"
    vless_ingress_run_checks "$egress_ip"
    vless_ingress_finalize "$egress_ip"
}

# vless_write_ingress_config <ip> <port> <uuid> <pub> <short_id> <sni>
vless_write_ingress_config() {
    local ip="$1" port="$2" uuid="$3" pub="$4" short_id="$5" sni="$6"
    local body
    body="${SB_MARKER}
// Role: vless ingress (client + TUN)
{
  \"log\": { \"level\": \"warn\", \"timestamp\": true },
  \"inbounds\": [
    {
      \"type\": \"tun\",
      \"tag\": \"tun-in\",
      \"interface_name\": \"${SB_TUN_IFACE}\",
      \"address\": [\"${SB_TUN_ADDR}\"],
      \"auto_route\": false,
      \"strict_route\": false,
      \"stack\": \"system\",
      \"sniff\": false
    }
  ],
  \"outbounds\": [
    {
      \"type\": \"vless\",
      \"tag\": \"vless-out\",
      \"server\": \"${ip}\",
      \"server_port\": ${port},
      \"uuid\": \"${uuid}\",
      \"flow\": \"xtls-rprx-vision\",
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${sni}\",
        \"utls\": { \"enabled\": true, \"fingerprint\": \"chrome\" },
        \"reality\": {
          \"enabled\": true,
          \"public_key\": \"${pub}\",
          \"short_id\": \"${short_id}\"
        }
      }
    },
    { \"type\": \"direct\", \"tag\": \"direct\" }
  ],
  \"route\": {
    \"rules\": [
      { \"inbound\": [\"tun-in\"], \"outbound\": \"vless-out\" }
    ]
  }
}"
    sb_write_config "$body"
}

# vless_ingress_run_checks <egress_ip>
vless_ingress_run_checks() {
    local egress_ip="$1"
    local fail=0

    local _i
    for _i in $(seq 1 20); do
        ip link show "$SB_TUN_IFACE" >/dev/null 2>&1 && break
        sleep 0.5
    done
    if ip link show "$SB_TUN_IFACE" >/dev/null 2>&1; then
        log_success "${SB_TUN_IFACE} поднят"
    else
        log_error "${SB_TUN_IFACE} не появился"; fail=1
    fi

    if ip route show table "$SB_TABLE_NAME" 2>/dev/null \
            | grep -q "default dev ${SB_TUN_IFACE}"; then
        log_success "В таблице ${SB_TABLE_NAME} есть default dev ${SB_TUN_IFACE}"
    else
        log_error "Нет default в таблице ${SB_TABLE_NAME}"; fail=1
    fi

    if ip rule show | grep -q "fwmark ${SB_FWMARK}.*lookup ${SB_TABLE_NAME}"; then
        log_success "ip rule fwmark ${SB_FWMARK} -> ${SB_TABLE_NAME}"
    else
        log_error "Нет ip rule для fwmark ${SB_FWMARK}"; fail=1
    fi

    if ip -4 route show default | grep -q "dev ${SB_TUN_IFACE}"; then
        log_error "Дефолтный маршрут идёт через ${SB_TUN_IFACE}"; fail=1
    else
        log_success "Дефолтный маршрут НЕ изменился"
    fi

    log_info "Проверка NAT через --interface ${SB_TUN_IFACE}..."
    local seen_ip=""
    seen_ip="$(curl -4 -fsS --max-time 20 --interface "$SB_TUN_IFACE" \
                    https://ifconfig.me 2>/dev/null || true)"
    seen_ip="$(trim "$seen_ip")"
    if [[ -z "$seen_ip" ]]; then
        log_error "Не удалось получить публичный IP через ${SB_TUN_IFACE}"; fail=1
    elif [[ "$seen_ip" == "$egress_ip" ]]; then
        log_success "NAT работает: трафик через ${SB_TUN_IFACE} уходит с IP ${seen_ip}"
    else
        log_error "Видимый IP=${seen_ip}, ожидался ${egress_ip}"; fail=1
    fi

    (( fail == 0 )) \
        || die "Часть проверок не прошла. См. $LOG_FILE и journalctl -u ${SB_SERVICE}"
}

# vless_ingress_finalize <egress_ip>
vless_ingress_finalize() {
    local egress_ip="$1"
    {
        printf '\n'
        banner "✓ INGRESS (VLESS+Reality+Vision) настроен"
        printf '\n'
        printf 'Туннель работает корректно:\n'
        printf '  ✓ TUN %s поднят, дефолт НЕ изменён\n' "$SB_TUN_IFACE"
        printf '  ✓ Policy routing активен (fwmark=%s → %s)\n' "$SB_FWMARK" "$SB_TUN_IFACE"
        printf '  ✓ NAT работает: трафик через %s уходит с IP %s\n\n' \
               "$SB_TUN_IFACE" "$egress_ip"
        printf 'Использование из приложений:\n'
        printf '  Любой сокет с SO_MARK=1 (например, Xray outbound c sockopt.mark=1)\n'
        printf '  пойдёт через туннель.\n\n'
        printf 'Логи: %s, journalctl -u %s -f\n\n' "$LOG_FILE" "$SB_SERVICE"
    }
}
