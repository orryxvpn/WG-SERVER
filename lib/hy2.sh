#!/usr/bin/env bash
# hy2.sh — Hysteria 2 driver. UDP/QUIC tunnel between INGRESS and EGRESS,
# implemented on top of sing-box.
#
# EGRESS: HY2 server with self-signed TLS masquerade (defaults to www.bing.com).
# INGRESS: HY2 client + sing-box TUN, with fwmark 0x1 -> singtun0 routing.

if [[ -n "${_WG_HY2_SOURCED:-}" ]]; then
    return 0
fi
_WG_HY2_SOURCED=1

# ------------------------------------------------------------------------------
# EGRESS
# ------------------------------------------------------------------------------

# hy2_egress_run <public_ip> <iface_unused>
hy2_egress_run() {
    local public_ip="$1"
    local port="${HY2_PORT:-${HY2_PORT_DEFAULT}}"
    local sni="${HY2_SNI:-${HY2_SNI_DEFAULT}}"

    {
        printf '\n'
        banner "EGRESS (Hysteria 2) — параметры установки"
        printf '\n'
        printf '  Внешний IP:        %s\n' "$public_ip"
        printf '  Listen port:       UDP %s\n' "$port"
        printf '  Маскировка SNI:    %s\n' "$sni"
        printf '\n'
    }
    if ! confirm "Продолжить?"; then
        die "Прервано пользователем."
    fi

    log_step "Установка sing-box"
    sb_install

    log_step "Генерация TLS-сертификата (self-signed, CN=${sni})"
    sb_gen_self_signed "$SB_DIR" "$sni"

    log_step "Генерация HY2-пароля"
    local password
    password="$(sb_genpsk_b64)"
    umask_secure
    printf '%s\n' "$password" >"$SB_DIR/hy2.password"
    chmod 600 "$SB_DIR/hy2.password"

    log_step "Запись /etc/sing-box/config.json"
    hy2_write_egress_config "$port" "$password" "$sni"

    log_step "Запуск sing-box"
    sb_start

    hy2_show_egress_bundle "$public_ip" "$port" "$password" "$sni"
    hy2_egress_run_checks "$port"
    hy2_egress_finalize
}

# hy2_write_egress_config <port> <password> <sni>
hy2_write_egress_config() {
    local port="$1"
    local password="$2"
    local sni="$3"
    local body
    body="${SB_MARKER}
// Role: hy2 egress (server)
{
  \"log\": { \"level\": \"warn\", \"timestamp\": true },
  \"inbounds\": [
    {
      \"type\": \"hysteria2\",
      \"tag\": \"hy2-in\",
      \"listen\": \"::\",
      \"listen_port\": ${port},
      \"users\": [{ \"password\": \"${password}\" }],
      \"masquerade\": \"https://${sni}\",
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${sni}\",
        \"alpn\": [\"h3\"],
        \"certificate_path\": \"${SB_DIR}/cert.pem\",
        \"key_path\": \"${SB_DIR}/cert.key\"
      }
    }
  ],
  \"outbounds\": [
    { \"type\": \"direct\", \"tag\": \"direct\" }
  ]
}"
    sb_write_config "$body"
}

# hy2_show_egress_bundle <ip> <port> <password> <sni>
# Print the secret bundle (base64-JSON) plus a human-readable breakdown.
hy2_show_egress_bundle() {
    local ip="$1" port="$2" password="$3" sni="$4"
    local bundle
    bundle="$(sb_encode_bundle \
        "proto=hy2" \
        "ip=${ip}" \
        "port=${port}" \
        "password=${password}" \
        "sni=${sni}")"
    {
        printf '\n'
        banner "ШАГ 1 ИЗ 2: данные для INGRESS-сервера"
        printf '\n'
        printf 'Скопируйте %sодну строку%s ниже целиком — это весь набор\n' "$C_BOLD" "$C_RESET"
        printf 'значений в одном base64-блоке. На INGRESS-сервере подставите его\n'
        printf 'в переменную HY2_BUNDLE и больше ничего вводить руками не нужно.\n\n'
        printf '%sHY2_BUNDLE:%s\n' "$C_BOLD" "$C_RESET"
        printf '  %s%s%s\n\n' "$C_GREEN" "$bundle" "$C_RESET"
        printf '%sРасшифровка (для глаза):%s\n' "$C_BOLD" "$C_RESET"
        printf '  ip:       %s\n' "$ip"
        printf '  port:     %s (UDP)\n' "$port"
        printf '  sni:      %s\n' "$sni"
        printf '  password: %s%s%s   %s(не публикуйте)%s\n' "$C_GREEN" "$password" "$C_RESET" "$C_YELLOW" "$C_RESET"
        printf '\nРекомендуемый запуск на INGRESS:\n'
        printf '  sudo -E HY2_BUNDLE=%q WG_REPO_REF=main bash setup.sh\n\n' "$bundle"
    }
    pause "Нажмите ENTER когда скопируете HY2_BUNDLE..."
}

# hy2_egress_run_checks <port>
hy2_egress_run_checks() {
    local port="$1"
    local fail=0
    if ! systemctl is-active --quiet "$SB_SERVICE"; then
        log_error "sing-box не запущен"
        fail=1
    else
        log_success "sing-box активен"
    fi
    if ss -ulnp 2>/dev/null | grep -qE ":${port}\\b"; then
        log_success "UDP ${port} прослушивается"
    else
        log_warn "UDP ${port} не виден через ss (возможно, ядерный сокет; не критично)"
    fi
    (( fail == 0 )) || die "Часть проверок не прошла. См. journalctl -u ${SB_SERVICE}"
}

hy2_egress_finalize() {
    {
        printf '\n'
        banner "✓ EGRESS (Hysteria 2) настроен"
        printf '\n'
        printf 'Дальнейшие шаги:\n'
        printf '  1. Скопированный HY2_BUNDLE передайте на INGRESS-сервер.\n'
        printf '  2. На INGRESS запустите setup.sh, выберите Hysteria 2 + INGRESS\n'
        printf '     или сразу подставьте через переменную.\n\n'
        printf 'Полезные команды:\n'
        printf '  systemctl status %s\n' "$SB_SERVICE"
        printf '  journalctl -u %s -f\n\n' "$SB_SERVICE"
        printf 'Логи установки: %s\n\n' "$LOG_FILE"
    }
}

# ------------------------------------------------------------------------------
# INGRESS
# ------------------------------------------------------------------------------

# hy2_ingress_run <public_ip> <iface_unused>
hy2_ingress_run() {
    local public_ip="$1"

    # Try the bundle first.
    local egress_ip="" port="" password="" sni=""
    if [[ -n "${HY2_BUNDLE:-}" ]]; then
        log_info "Распаковка HY2_BUNDLE"
        sb_decode_bundle_to_var "$HY2_BUNDLE" "ip"       egress_ip || die "Битый HY2_BUNDLE: нет 'ip'"
        sb_decode_bundle_to_var "$HY2_BUNDLE" "port"     port      || die "Битый HY2_BUNDLE: нет 'port'"
        sb_decode_bundle_to_var "$HY2_BUNDLE" "password" password  || die "Битый HY2_BUNDLE: нет 'password'"
        sb_decode_bundle_to_var "$HY2_BUNDLE" "sni"      sni       || sni="${HY2_SNI:-$HY2_SNI_DEFAULT}"
        is_valid_ipv4 "$egress_ip" || die "HY2_BUNDLE.ip не похож на IPv4: $egress_ip"
        log_info "EGRESS IP=${egress_ip}, port=${port}, sni=${sni}"
    else
        # Individual env vars or interactive prompts.
        if [[ -n "${HY2_EGRESS_IP:-}" ]] && is_valid_ipv4 "${HY2_EGRESS_IP}"; then
            egress_ip="${HY2_EGRESS_IP}"
        else
            prompt_ipv4 egress_ip "EGRESS IP (публичный): "
        fi
        port="${HY2_PORT:-${HY2_PORT_DEFAULT}}"
        if [[ -n "${HY2_PASSWORD:-}" ]]; then
            password="${HY2_PASSWORD}"
        else
            log_warn "HY2_PASSWORD не задана. Лучше использовать HY2_BUNDLE."
            read_tty password "HY2 PASSWORD (с egress): "
            [[ -n "$password" ]] || die "Пустой пароль."
        fi
        sni="${HY2_SNI:-${HY2_SNI_DEFAULT}}"
    fi

    {
        printf '\n'
        banner "INGRESS (Hysteria 2) — параметры установки"
        printf '\n'
        printf '  Внешний IP (этот сервер):  %s\n' "$public_ip"
        printf '  EGRESS endpoint:           %s:%s (UDP)\n' "$egress_ip" "$port"
        printf '  Маскировка SNI:            %s\n' "$sni"
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
    hy2_write_ingress_config "$egress_ip" "$port" "$password" "$sni"

    log_step "Запуск sing-box"
    sb_start

    log_step "Установка systemd-юнита для policy routing"
    sb_install_ingress_routing_units

    log_step "Проверки"
    hy2_ingress_run_checks "$egress_ip"
    hy2_ingress_finalize "$egress_ip"
}

# hy2_write_ingress_config <egress_ip> <port> <password> <sni>
hy2_write_ingress_config() {
    local ip="$1" port="$2" password="$3" sni="$4"
    local body
    body="${SB_MARKER}
// Role: hy2 ingress (client + TUN)
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
      \"type\": \"hysteria2\",
      \"tag\": \"hy2-out\",
      \"server\": \"${ip}\",
      \"server_port\": ${port},
      \"password\": \"${password}\",
      \"tls\": {
        \"enabled\": true,
        \"server_name\": \"${sni}\",
        \"insecure\": true,
        \"alpn\": [\"h3\"]
      }
    },
    { \"type\": \"direct\", \"tag\": \"direct\" }
  ],
  \"route\": {
    \"rules\": [
      { \"inbound\": [\"tun-in\"], \"outbound\": \"hy2-out\" }
    ]
  }
}"
    sb_write_config "$body"
}

# hy2_ingress_run_checks <egress_ip>
hy2_ingress_run_checks() {
    local egress_ip="$1"
    local fail=0

    # Wait for the TUN interface to appear (sing-box creates it on start).
    local _i
    for _i in $(seq 1 20); do
        ip link show "$SB_TUN_IFACE" >/dev/null 2>&1 && break
        sleep 0.5
    done
    if ip link show "$SB_TUN_IFACE" >/dev/null 2>&1; then
        log_success "${SB_TUN_IFACE} поднят"
    else
        log_error "${SB_TUN_IFACE} не появился — sing-box, видимо, не стартовал"
        fail=1
    fi

    if ip route show table "$SB_TABLE_NAME" 2>/dev/null \
            | grep -q "default dev ${SB_TUN_IFACE}"; then
        log_success "В таблице ${SB_TABLE_NAME} есть default dev ${SB_TUN_IFACE}"
    else
        log_error "В таблице ${SB_TABLE_NAME} нет default dev ${SB_TUN_IFACE}"
        fail=1
    fi

    if ip rule show | grep -q "fwmark ${SB_FWMARK}.*lookup ${SB_TABLE_NAME}"; then
        log_success "ip rule fwmark ${SB_FWMARK} -> ${SB_TABLE_NAME} установлено"
    else
        log_error "Нет ip rule для fwmark ${SB_FWMARK}"
        fail=1
    fi

    if ip -4 route show default | grep -q "dev ${SB_TUN_IFACE}"; then
        log_error "Дефолтный маршрут идёт через ${SB_TUN_IFACE} — это не должно происходить"
        fail=1
    else
        log_success "Дефолтный маршрут НЕ изменился"
    fi

    log_info "Проверка NAT через --interface ${SB_TUN_IFACE}..."
    local seen_ip=""
    seen_ip="$(curl -4 -fsS --max-time 20 --interface "$SB_TUN_IFACE" \
                    https://ifconfig.me 2>/dev/null || true)"
    seen_ip="$(trim "$seen_ip")"
    if [[ -z "$seen_ip" ]]; then
        log_error "Не удалось получить публичный IP через --interface ${SB_TUN_IFACE}"
        fail=1
    elif [[ "$seen_ip" == "$egress_ip" ]]; then
        log_success "NAT работает: трафик через ${SB_TUN_IFACE} уходит с IP ${seen_ip} (= EGRESS)"
    else
        log_error "Публичный IP через ${SB_TUN_IFACE} = ${seen_ip}, ожидался ${egress_ip}"
        fail=1
    fi

    (( fail == 0 )) \
        || die "Часть проверок не прошла. См. $LOG_FILE и journalctl -u ${SB_SERVICE}"
}

# hy2_ingress_finalize <egress_ip>
hy2_ingress_finalize() {
    local egress_ip="$1"
    {
        printf '\n'
        banner "✓ INGRESS (Hysteria 2) настроен и проверен"
        printf '\n'
        printf 'Туннель работает корректно:\n'
        printf '  ✓ TUN %s поднят, дефолт НЕ изменён\n' "$SB_TUN_IFACE"
        printf '  ✓ Policy routing активен (fwmark=%s → %s)\n' "$SB_FWMARK" "$SB_TUN_IFACE"
        printf '  ✓ NAT работает: трафик через %s уходит с IP %s\n\n' \
               "$SB_TUN_IFACE" "$egress_ip"
        printf 'Использование из приложений:\n'
        printf '  Любой сокет с SO_MARK=1 (например, Xray outbound c sockopt.mark=1)\n'
        printf '  пойдёт через туннель. Без mark — через основной канал.\n\n'
        printf 'Логи: %s, journalctl -u %s -f\n\n' "$LOG_FILE" "$SB_SERVICE"
    }
}
