#!/usr/bin/env bash
# Автоустановка сервера 1 (входной, РФ) для схемы dual-server.
# Сервер 2 уже должен работать (VPN-XRAY + patch-server2.sh).
#
#   scp relay-server1-params.json root@SERVER1:/usr/local/etc/xray/
#   sudo ./install-server1.sh
#   sudo ./install-server1.sh --relay-file /usr/local/etc/xray/relay-server1-params.json -y

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly CLIENT_PORT="${CLIENT_PORT:-443}"
readonly RELAY_FILE_DEFAULT="${CONFIG_DIR}/relay-server1-params.json"
# Маскировка REALITY под Яндекс Музыку (TLS 1.3, легитимный трафик в РФ)
readonly REALITY_DEST_DEFAULT="${REALITY_DEST_DEFAULT:-music.yandex.ru:443}"
readonly REALITY_SNI_DEFAULT="${REALITY_SNI_DEFAULT:-music.yandex.ru}"

RELAY_FILE=""
NON_INTERACTIVE=false

usage() {
    cat << 'EOF'
Использование: sudo ./install-server1.sh [опции]

Устанавливает Xray на сервер 1: REALITY для клиентов + маршрутизация
  geoip:ru / geosite:ru → прямой выход
  остальное → relay на сервер 2

Опции:
  --relay-file PATH   Файл relay-server1-params.json с сервера 2
  -y, --yes           Значения по умолчанию (порт 443, music.yandex.ru, 1 пользователь)
  -h, --help          Справка

Перед запуском на сервере 2 выполните: sudo ./patch-server2.sh
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --relay-file) RELAY_FILE="$2"; shift 2 ;;
            -y|--yes) NON_INTERACTIVE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) log_err "Неизвестный аргумент: $1"; usage; exit 1 ;;
        esac
    done
    [[ -z "${RELAY_FILE}" && -f "${RELAY_FILE_DEFAULT}" ]] && RELAY_FILE="${RELAY_FILE_DEFAULT}"
}

load_relay_params() {
    if [[ ! -f "${RELAY_FILE}" ]]; then
        log_err "Не найден ${RELAY_FILE}"
        log_err "Сначала на сервере 2: sudo ./patch-server2.sh"
        log_err "Затем: scp root@SERVER2:${RELAY_FILE_DEFAULT} ."
        exit 1
    fi
    SERVER2_HOST=$(jq -r '.server2Host' "${RELAY_FILE}")
    RELAY_PORT=$(jq -r '.relayPort' "${RELAY_FILE}")
    RELAY_UUID=$(jq -r '.relayUuid' "${RELAY_FILE}")
    RELAY_SNI=$(jq -r '.relaySni // "vpn-relay.internal"' "${RELAY_FILE}")
    cp -f "${RELAY_FILE}" "${CONFIG_DIR}/relay-server1-params.json"
    chmod 600 "${CONFIG_DIR}/relay-server1-params.json"
    log_info "Relay: ${SERVER2_HOST}:${RELAY_PORT}"
}

prompt_or_default() {
    local var_name="$1"
    local prompt="$2"
    local default="$3"
    if [[ "${NON_INTERACTIVE}" == true ]]; then
        printf -v "${var_name}" '%s' "${default}"
        return
    fi
    read -rp "${prompt} [${default}]: " input
    printf -v "${var_name}" '%s' "${input:-$default}"
}

main() {
    parse_args "$@"
    check_root
    install_deps
    load_relay_params
    install_xray
    install_geodata

    echo ""
    log_info "=== Установка сервера 1 (split RU / abroad) ==="
    echo ""

    local PORT DEST SNI_INPUT FINGERPRINT NUSERS
    prompt_or_default PORT "Порт REALITY для клиентов" "${CLIENT_PORT}"
    prompt_or_default DEST "dest (маскировка TLS, Яндекс Музыка)" "${REALITY_DEST_DEFAULT}"
    prompt_or_default SNI_INPUT "serverNames (SNI)" "${REALITY_SNI_DEFAULT}"
    prompt_or_default FINGERPRINT "Fingerprint" "chrome"
    prompt_or_default NUSERS "Количество пользователей" "1"

    IFS=',' read -ra SNI_ARR <<< "${SNI_INPUT}"
    local SERVER_NAMES_JSON
    SERVER_NAMES_JSON=$(printf '"%s",' "${SNI_ARR[@]}" | sed 's/,$//')
    SERVER_NAMES_JSON="[ ${SERVER_NAMES_JSON} ]"

    SHORT_IDS="[]"
    CLIENT_JSON=""
    for ((i = 0; i < NUSERS; i++)); do
        local sid uuid
        sid=$(generate_short_id 4)
        uuid=$(generate_uuid)
        SHORT_IDS=$(echo "${SHORT_IDS}" | jq --arg s "${sid}" '. + [$s]')
        if [[ $i -eq 0 ]]; then
            CLIENT_JSON="{\"id\": \"${uuid}\", \"flow\": \"xtls-rprx-vision\"}"
        else
            CLIENT_JSON="${CLIENT_JSON}, {\"id\": \"${uuid}\", \"flow\": \"xtls-rprx-vision\"}"
        fi
        echo "  Пользователь $((i + 1)): UUID=${uuid}, shortId=${sid}"
    done
    CLIENT_JSON="[ ${CLIENT_JSON} ]"

    local KEY_PAIR
    KEY_PAIR=$(generate_x25519)
    parse_x25519 "${KEY_PAIR}"
    EXTERNAL_IP=$(get_external_ip)

    log_info "IP сервера 1: ${EXTERNAL_IP}"
    log_info "Зарубежный трафик → ${SERVER2_HOST}:${RELAY_PORT}"

    cat > "${CONFIG_FILE}" << EOF
{
  "log": { "loglevel": "error" },
  "dns": {
    "servers": [
      {
        "address": "https://dns.google/dns-query",
        "domains": ["geosite:geolocation-!cn"],
        "skipFallback": true
      },
      {
        "address": "https://common.dot.dns.yandex.net/dns-query",
        "domains": ["geosite:ru"],
        "skipFallback": false
      },
      "localhost"
    ],
    "queryStrategy": "UseIPv4"
  },
  "inbounds": [
    {
      "port": ${PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": ${CLIENT_JSON},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "${DEST}",
          "serverNames": ${SERVER_NAMES_JSON},
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ${SHORT_IDS}
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      },
      "tag": "reality-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER2_HOST}",
            "port": ${RELAY_PORT},
            "users": [
              {
                "id": "${RELAY_UUID}",
                "encryption": "none",
                "flow": "xtls-rprx-vision"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "serverName": "${RELAY_SNI}",
          "allowInsecure": true,
          "fingerprint": "chrome"
        }
      },
      "tag": "proxy-abroad"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["geoip:ru"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": ["geosite:ru"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "proxy-abroad"
      }
    ]
  }
}
EOF

    validate_xray_config
    install_systemd
    setup_ufw_ports "${PORT}"

    local first_sni="${SNI_ARR[0]}"
    local client_info="${CONFIG_DIR}/reality-client-params.json"

    jq -n \
        --arg host "${EXTERNAL_IP}" \
        --argjson port "${PORT}" \
        --arg pk "${PUBLIC_KEY}" \
        --arg fp "${FINGERPRINT}" \
        --arg sni "${first_sni}" \
        --argjson sids "${SHORT_IDS}" \
        --argjson users "${CLIENT_JSON}" \
        --arg role "server1-primary" \
        --arg s2 "${SERVER2_HOST}" \
        '{
          role: $role,
          serverHost: $host,
          serverPort: $port,
          publicKey: $pk,
          fingerprint: $fp,
          serverName: $sni,
          shortIds: $sids,
          users: $users,
          server2Host: $s2,
          routing: "geoip:ru -> direct, other -> server2"
        }' > "${client_info}"

    chmod 600 "${client_info}"

    echo ""
    echo "=============================================="
    log_info "Сервер 1 установлен."
    echo "=============================================="
    echo "Основной профиль (новый): ${client_info}"
    echo "Резерв (старый сервер 2): ${CONFIG_DIR}/reality-client-params.json на SERVER2"
    echo ""
    echo "Ссылки на ПК:"
    echo "  python dual-server/client/dual-link-gen.py server1-client-params.json server2-client-params.json"
    echo "=============================================="
}

main "$@"
