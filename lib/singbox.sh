#!/usr/bin/env bash
# singbox.sh — shared helpers for sing-box-based protocols (Hysteria 2,
# VLESS+Reality). Sourced by lib/hy2.sh and lib/vless.sh.
#
# Responsibilities:
#   * install sing-box from the official deb repo (stable channel)
#   * write /etc/sing-box/config.json atomically with a marker we can
#     find later for uninstall / reinstall detection
#   * generate self-signed TLS material for Hysteria 2
#   * generate Reality keypair / UUID / short-id for VLESS
#   * encode / decode the egress→ingress secret bundle as base64-JSON
#     (one paste → all values, validated as a single unit)
#   * set up policy routing on ingress so traffic with fwmark 0x1
#     leaves through the sing-box TUN

if [[ -n "${_WG_SINGBOX_SOURCED:-}" ]]; then
    return 0
fi
_WG_SINGBOX_SOURCED=1

# ------------------------------------------------------------------------------
# Constants
# ------------------------------------------------------------------------------
SB_DIR="${SB_DIR:-/etc/sing-box}"
SB_CONFIG="${SB_CONFIG:-${SB_DIR}/config.json}"
SB_SERVICE="${SB_SERVICE:-sing-box}"
SB_TUN_IFACE="${SB_TUN_IFACE:-singtun0}"
SB_TUN_ADDR="${SB_TUN_ADDR:-198.18.0.1/30}"
SB_TABLE_ID="${SB_TABLE_ID:-201}"
SB_TABLE_NAME="${SB_TABLE_NAME:-sbox}"
SB_FWMARK="${SB_FWMARK:-0x1}"
# shellcheck disable=SC2034  # consumed by lib/hy2.sh and lib/vless.sh
SB_MARKER="// wg-tunnel-setup v${SCRIPT_VERSION}"

# Default ports / SNIs. Each can be overridden via env when calling setup.sh.
HY2_PORT_DEFAULT="${HY2_PORT_DEFAULT:-8443}"
HY2_SNI_DEFAULT="${HY2_SNI_DEFAULT:-www.bing.com}"
VLESS_PORT_DEFAULT="${VLESS_PORT_DEFAULT:-443}"
VLESS_DEST_DEFAULT="${VLESS_DEST_DEFAULT:-www.cloudflare.com:443}"
VLESS_SNI_DEFAULT="${VLESS_SNI_DEFAULT:-www.cloudflare.com}"

# ------------------------------------------------------------------------------
# Install / service management
# ------------------------------------------------------------------------------

# sb_install — install sing-box from the official Debian/Ubuntu repo.
# Idempotent: skips if sing-box is already installed.
sb_install() {
    if command -v sing-box >/dev/null 2>&1; then
        log_info "sing-box уже установлен: $(sing-box version | head -1)"
        return 0
    fi
    log_info "Подключается официальный репозиторий sing-box"
    install_packages curl ca-certificates gnupg
    install -d -m 0755 /etc/apt/keyrings
    if [[ ! -s /etc/apt/keyrings/sagernet.asc ]]; then
        curl -fsSL https://sing-box.app/gpg.key \
            -o /etc/apt/keyrings/sagernet.asc \
            >>"$LOG_FILE" 2>&1 \
            || die "Не удалось скачать GPG-ключ sing-box. См. $LOG_FILE"
        chmod 0644 /etc/apt/keyrings/sagernet.asc
    fi
    cat >/etc/apt/sources.list.d/sagernet.sources <<EOF
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
    log_info "Устанавливается пакет sing-box"
    DEBIAN_FRONTEND=noninteractive apt-get update -qq >>"$LOG_FILE" 2>&1 \
        || die "apt-get update упал. См. $LOG_FILE"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq sing-box \
        >>"$LOG_FILE" 2>&1 \
        || die "Не удалось установить sing-box. См. $LOG_FILE"
    log_success "sing-box установлен: $(sing-box version | head -1)"
}

# sb_write_config <body>
# Atomically write /etc/sing-box/config.json. Body must be valid JSON
# (we don't validate it here; sing-box check runs after).
sb_write_config() {
    local body="$1"
    umask_secure
    mkdir -p "$SB_DIR"
    chmod 700 "$SB_DIR"
    printf '%s\n' "$body" | atomic_write "$SB_CONFIG" 600
    if ! sing-box check -c "$SB_CONFIG" >>"$LOG_FILE" 2>&1; then
        die "sing-box check отверг конфиг $SB_CONFIG. См. $LOG_FILE"
    fi
    log_success "Записан $SB_CONFIG"
}

# sb_start — enable + (re)start sing-box.service.
sb_start() {
    if systemctl is-active --quiet "${SB_SERVICE}"; then
        systemctl restart "${SB_SERVICE}" >>"$LOG_FILE" 2>&1 \
            || die "sing-box restart упал. См. journalctl -u ${SB_SERVICE}"
    else
        systemctl enable "${SB_SERVICE}" >>"$LOG_FILE" 2>&1 || true
        systemctl start "${SB_SERVICE}" >>"$LOG_FILE" 2>&1 \
            || die "sing-box start упал. См. journalctl -u ${SB_SERVICE}"
    fi
    log_success "sing-box запущен"
}

# sb_stop — stop + disable. Used by uninstall.
sb_stop() {
    systemctl disable --now "${SB_SERVICE}" >>"$LOG_FILE" 2>&1 || true
}

# ------------------------------------------------------------------------------
# Crypto helpers
# ------------------------------------------------------------------------------

# sb_genpsk_b64 — print a fresh 32-byte random secret as base64-url.
sb_genpsk_b64() {
    head -c 32 /dev/urandom | base64 -w0
}

# sb_gen_uuid — generate a random UUIDv4. Falls back to /proc/sys/kernel/random/uuid.
sb_gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# sb_gen_short_id — 8-byte hex string (16 chars).
sb_gen_short_id() {
    head -c 8 /dev/urandom | od -An -tx1 | tr -d ' \n'
}

# sb_gen_reality_keypair_to <out_dir>
# Run `sing-box generate reality-keypair` and write two files:
#   <out_dir>/reality_private.key
#   <out_dir>/reality_public.key
# The CLI prints lines like:
#   PrivateKey: yA...
#   PublicKey: zB...
sb_gen_reality_keypair_to() {
    local out_dir="$1"
    umask_secure
    mkdir -p "$out_dir"
    chmod 700 "$out_dir"
    local raw priv pub
    raw="$(sing-box generate reality-keypair 2>/dev/null)"
    priv="$(awk -F': *' '/^PrivateKey/ {print $2; exit}' <<<"$raw")"
    pub="$(awk -F': *' '/^PublicKey/ {print $2; exit}' <<<"$raw")"
    if [[ -z "$priv" || -z "$pub" ]]; then
        die "sing-box generate reality-keypair вернул пустой ответ"
    fi
    printf '%s\n' "$priv" >"$out_dir/reality_private.key"
    printf '%s\n' "$pub"  >"$out_dir/reality_public.key"
    chmod 600 "$out_dir/reality_private.key"
    chmod 644 "$out_dir/reality_public.key"
}

# sb_gen_self_signed <out_dir> <cn>
# Generate a self-signed TLS keypair for HY2's masquerade.
sb_gen_self_signed() {
    local out_dir="$1"
    local cn="$2"
    umask_secure
    mkdir -p "$out_dir"
    chmod 700 "$out_dir"
    if ! command -v openssl >/dev/null 2>&1; then
        install_packages openssl
    fi
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout "$out_dir/cert.key" -out "$out_dir/cert.pem" \
        -subj "/CN=${cn}" -days 3650 \
        >>"$LOG_FILE" 2>&1 \
        || die "openssl не смог сгенерировать self-signed cert. См. $LOG_FILE"
    chmod 600 "$out_dir/cert.key"
    chmod 644 "$out_dir/cert.pem"
}

# ------------------------------------------------------------------------------
# Bundle (egress→ingress secret transport)
# ------------------------------------------------------------------------------

# sb_encode_bundle <key1=val1> <key2=val2> ...
# Build a JSON object from the kv pairs and base64-encode it without padding.
# The result is one line, easy to copy. Use sb_decode_bundle on ingress to
# unpack.
sb_encode_bundle() {
    local kv key val
    local pairs=()
    for kv in "$@"; do
        key="${kv%%=*}"
        val="${kv#*=}"
        # Escape backslashes and double quotes for JSON.
        val="${val//\\/\\\\}"
        val="${val//\"/\\\"}"
        pairs+=("\"$key\":\"$val\"")
    done
    local joined
    joined="$(IFS=,; printf '%s' "${pairs[*]}")"
    printf '{%s}' "$joined" | base64 -w0
}

# sb_decode_bundle_to_var <bundle> <key> <out_varname>
# Decode the bundle (base64-JSON) and pull out <key>; write into <out_varname>.
# Returns non-zero if the bundle is unparseable or the key is missing.
sb_decode_bundle_to_var() {
    local bundle="$1"
    local key="$2"
    local out="$3"
    local json
    if ! json="$(printf '%s' "$bundle" | base64 -d 2>/dev/null)"; then
        return 1
    fi
    # Best-effort grep extraction. We control the encoding (no nested objects,
    # no embedded quotes after our escaping) so this is safe enough without
    # pulling in jq.
    local val
    val="$(grep -oP "\"${key}\"\\s*:\\s*\"\\K[^\"]*" <<<"$json" | head -1)"
    [[ -n "$val" ]] || return 1
    printf -v "$out" '%s' "$val"
}

# ------------------------------------------------------------------------------
# Ingress-side routing (TUN + fwmark policy routing)
# ------------------------------------------------------------------------------

# sb_register_rt_table — add `<id> <name>` to /etc/iproute2/rt_tables. Idempotent.
sb_register_rt_table() {
    local rt="/etc/iproute2/rt_tables"
    if [[ ! -f "$rt" ]]; then
        printf '#\n# reserved values\n#\n255\tlocal\n254\tmain\n253\tdefault\n0\tunspec\n' >"$rt"
    fi
    if ! awk -v id="$SB_TABLE_ID" -v name="$SB_TABLE_NAME" \
            '$1==id || $2==name {found=1} END{exit !found}' "$rt"; then
        printf '%s\t%s\n' "$SB_TABLE_ID" "$SB_TABLE_NAME" >>"$rt"
        log_info "Добавлено '${SB_TABLE_ID} ${SB_TABLE_NAME}' в $rt"
    fi
}

# sb_write_ingress_sysctl — sysctl drop-in for ingress-side policy routing.
sb_write_ingress_sysctl() {
    local body
    body="# wg-tunnel-setup v${SCRIPT_VERSION}
# Policy routing for sing-box-based tunnel (ingress side)
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.default.src_valid_mark = 1"
    write_sysctl "99-wg-singbox-ingress.conf" "$body"
}

# sb_install_ingress_routing_units
# Drop a tiny systemd service that owns the fwmark→TUN ip rule + table
# default route. It binds to sing-box.service so it goes up/down together.
# We do this via a separate unit (rather than ExecStartPost on sing-box)
# so a sing-box restart doesn't end up duplicating rules.
sb_install_ingress_routing_units() {
    local helper="/usr/local/sbin/wg-tunnel-singbox-routing"
    cat >"$helper" <<EOF
#!/bin/sh
# Generated by wg-tunnel-setup v${SCRIPT_VERSION}.
# Manage policy routing for the sing-box TUN. Idempotent: safe to call
# 'up' twice, 'down' on already-clean state.
set -eu
CMD="\${1:-up}"
TABLE="${SB_TABLE_NAME}"
IFACE="${SB_TUN_IFACE}"
FWMARK="${SB_FWMARK}"

case "\$CMD" in
    up)
        # Wait briefly for the TUN interface to appear (sing-box creates it
        # on startup; we run shortly after).
        i=0
        while [ \$i -lt 30 ] && ! ip link show "\$IFACE" >/dev/null 2>&1; do
            i=\$((i+1)); sleep 0.5
        done
        ip link show "\$IFACE" >/dev/null 2>&1 || {
            echo "wg-tunnel-singbox-routing: \$IFACE did not appear" >&2
            exit 1
        }
        ip route replace default dev "\$IFACE" table "\$TABLE"
        ip rule add fwmark "\$FWMARK" lookup "\$TABLE" priority 100 2>/dev/null || true
        ;;
    down)
        ip rule del fwmark "\$FWMARK" lookup "\$TABLE" priority 100 2>/dev/null || true
        ip route flush table "\$TABLE" 2>/dev/null || true
        ;;
    *)
        echo "usage: \$0 up|down" >&2
        exit 2
        ;;
esac
EOF
    chmod 755 "$helper"

    local unit="/etc/systemd/system/wg-tunnel-singbox-routing.service"
    cat >"$unit" <<EOF
[Unit]
# Generated by wg-tunnel-setup v${SCRIPT_VERSION}.
Description=wg-tunnel-setup: policy routing for sing-box TUN
After=sing-box.service
BindsTo=sing-box.service
Requires=sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=${helper} up
ExecStop=${helper} down

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$unit"
    systemctl daemon-reload
    systemctl enable --now wg-tunnel-singbox-routing.service \
        >>"$LOG_FILE" 2>&1 \
        || log_warn "Не удалось поднять wg-tunnel-singbox-routing.service. См. journalctl -u wg-tunnel-singbox-routing"
}

# sb_remove_ingress_routing_units — counterpart of install.
sb_remove_ingress_routing_units() {
    systemctl disable --now wg-tunnel-singbox-routing.service \
        >>"$LOG_FILE" 2>&1 || true
    rm -f /etc/systemd/system/wg-tunnel-singbox-routing.service
    rm -f /usr/local/sbin/wg-tunnel-singbox-routing
    systemctl daemon-reload || true
    ip rule del fwmark "$SB_FWMARK" lookup "$SB_TABLE_NAME" priority 100 \
        >/dev/null 2>&1 || true
    ip route flush table "$SB_TABLE_NAME" >/dev/null 2>&1 || true
}

# sb_uninstall_files <role>
# Remove files this script owns. <role> is "egress" or "ingress".
sb_uninstall_files() {
    local role="$1"
    sb_stop
    rm -f "$SB_CONFIG"
    rm -f "$SB_DIR/cert.pem" "$SB_DIR/cert.key"
    rm -f "$SB_DIR/reality_private.key" "$SB_DIR/reality_public.key"
    rm -f "$SB_DIR/hy2.password" "$SB_DIR/vless.uuid"
    rmdir "$SB_DIR" 2>/dev/null || true
    rm -f /etc/sysctl.d/99-wg-singbox-ingress.conf
    if [[ "$role" == "ingress" ]]; then
        sb_remove_ingress_routing_units
        if [[ -f /etc/iproute2/rt_tables ]]; then
            sed -i.bak \
                -e "/^${SB_TABLE_ID}[[:space:]]\\+${SB_TABLE_NAME}\\b/d" \
                /etc/iproute2/rt_tables
            rm -f /etc/iproute2/rt_tables.bak
        fi
    fi
    sysctl --system >>"$LOG_FILE" 2>&1 || true
}
