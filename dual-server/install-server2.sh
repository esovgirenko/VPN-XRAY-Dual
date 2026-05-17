#!/usr/bin/env bash
# Сервер 2 (зарубежный): вход для клиентов (резерв) + relay для сервера 1
# Устанавливайте ПЕРВЫМ. Ubuntu 22.04 / Debian 12, root.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly RELAY_PORT="${RELAY_PORT:-8443}"
readonly CLIENT_PORT="${CLIENT_PORT:-443}"

main() {
    check_root
    install_deps
    install_xray
    install_geodata

    echo ""
    log_info "=== Сервер 2 (зарубежный выход + резервный вход) ==="
    log_info "Клиенты подключаются сюда напрямую, если сервер 1 недоступен."
    echo ""

    read -rp "Порт REALITY для клиентов [${CLIENT_PORT}]: " PORT
    PORT="${PORT:-$CLIENT_PORT}"

    read -rp "dest (маскировка TLS) [www.cloudflare.com:443]: " DEST
    DEST="${DEST:-www.cloudflare.com:443}"

    read -rp "serverNames (SNI) [www.cloudflare.com,cloudflare.com]: " SNI_INPUT
    SNI_INPUT="${SNI_INPUT:-www.cloudflare.com,cloudflare.com}"
    IFS=',' read -ra SNI_ARR <<< "${SNI_INPUT}"
    SERVER_NAMES_JSON=$(printf '"%s",' "${SNI_ARR[@]}" | sed 's/,$//')
    SERVER_NAMES_JSON="[ ${SERVER_NAMES_JSON} ]"

    read -rp "Fingerprint [chrome]: " FINGERPRINT
    FINGERPRINT="${FINGERPRINT:-chrome}"

    read -rp "Количество пользователей [1]: " NUSERS
    NUSERS="${NUSERS:-1}"

    SHORT_IDS="[]"
    CLIENT_JSON=""
    for ((i = 0; i < NUSERS; i++)); do
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

    KEY_PAIR=$(generate_x25519)
    parse_x25519 "${KEY_PAIR}"
    RELAY_UUID=$(generate_uuid)
    EXTERNAL_IP=$(get_external_ip)
    RELAY_TLS_DIR=$(generate_relay_tls)

    log_info "Внешний IP сервера 2: ${EXTERNAL_IP}"
    log_info "Relay UUID (для сервера 1): ${RELAY_UUID}"
    log_info "Relay порт: ${RELAY_PORT}"

    cat > "${CONFIG_FILE}" << EOF
{
  "log": { "loglevel": "error" },
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
    },
    {
      "port": ${RELAY_PORT},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${RELAY_UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "${RELAY_TLS_DIR}/cert.pem",
              "keyFile": "${RELAY_TLS_DIR}/key.pem"
            }
          ]
        }
      },
      "tag": "relay-in"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct"
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": ["relay-in"],
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

    validate_xray_config
    install_systemd
    setup_ufw_ports "${PORT}" "${RELAY_PORT}"

    local first_sni="${SNI_ARR[0]}"
    local client_info="${CONFIG_DIR}/reality-client-params.json"
    local relay_info="${CONFIG_DIR}/relay-server1-params.json"

    jq -n \
        --arg host "${EXTERNAL_IP}" \
        --argjson port "${PORT}" \
        --arg pk "${PUBLIC_KEY}" \
        --arg fp "${FINGERPRINT}" \
        --arg sni "${first_sni}" \
        --argjson sids "${SHORT_IDS}" \
        --argjson users "${CLIENT_JSON}" \
        --arg role "server2-fallback" \
        '{
          role: $role,
          serverHost: $host,
          serverPort: $port,
          publicKey: $pk,
          fingerprint: $fp,
          serverName: $sni,
          shortIds: $sids,
          users: $users
        }' > "${client_info}"

    jq -n \
        --arg host "${EXTERNAL_IP}" \
        --argjson port "${RELAY_PORT}" \
        --arg uuid "${RELAY_UUID}" \
        --arg cert "${RELAY_TLS_DIR}/cert.pem" \
        '{
          server2Host: $host,
          relayPort: $port,
          relayUuid: $uuid,
          relayTlsCert: $cert,
          relaySni: "vpn-relay.internal"
        }' > "${relay_info}"

    chmod 600 "${CONFIG_FILE}" "${client_info}" "${relay_info}"

    echo ""
    echo "=============================================="
    log_info "Сервер 2 установлен."
    echo "=============================================="
    echo "Файлы:"
    echo "  ${client_info}          — параметры для клиентов (резерв)"
    echo "  ${relay_info}           — передайте на сервер 1"
    echo ""
    echo "Скопируйте relay-server1-params.json на сервер 1 перед установкой server1."
    echo "Скачайте reality-client-params.json для генерации ссылок (резерв)."
    echo "=============================================="
}

main "$@"
