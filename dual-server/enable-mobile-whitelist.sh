#!/usr/bin/env bash
# Дополнительный inbound для мобильного интернета с «белыми списками» оператора.
# Не трогает основной :443 (music.yandex.ru) — добавляет профиль на порту 2053.
#
#   sudo ./enable-mobile-whitelist.sh
#   sudo ./enable-mobile-whitelist.sh --dest vk --port 2053

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

WHITELIST_PORT="${WHITELIST_PORT:-2053}"
WHITELIST_PRESET="${WHITELIST_PRESET:-vk}"

usage() {
    cat << 'EOF'
Использование: sudo ./enable-mobile-whitelist.sh [опции]

Добавляет второй REALITY-inbound для мобильных сетей с SNI из «белого списка».
Основной профиль :443 не изменяется.

Опции:
  --port PORT       Порт мобильного профиля [2053]
  --dest PRESET     vk | yandex | ozon  (dest/SNI для маскировки)
  -h, --help

После запуска: reality-client-params-mobile.json и ссылка через reality-link-gen.py --mobile
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --port) WHITELIST_PORT="$2"; shift 2 ;;
            --dest) WHITELIST_PRESET="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) log_err "Неизвестный аргумент: $1"; usage; exit 1 ;;
        esac
    done
}

set_whitelist_dest() {
    case "${WHITELIST_PRESET}" in
        vk)
            WL_DEST="eh.vk.com:443"
            WL_SNI='["eh.vk.com", "vk.com", "www.vk.com"]'
            WL_FP="ios"
            ;;
        yandex)
            WL_DEST="music.yandex.ru:443"
            WL_SNI='["music.yandex.ru", "yandex.ru", "www.yandex.ru"]'
            WL_FP="chrome"
            ;;
        ozon)
            WL_DEST="www.ozon.ru:443"
            WL_SNI='["www.ozon.ru", "ozon.ru"]'
            WL_FP="chrome"
            ;;
        *)
            log_err "Неизвестный preset: ${WHITELIST_PRESET} (vk|yandex|ozon)"
            exit 1
            ;;
    esac
}

main() {
    parse_args "$@"
    check_root
    require_xray_installed
    command -v jq &>/dev/null || install_deps

    if ! jq -e '.inbounds[] | select(.tag == "reality-in")' "${CONFIG_FILE}" >/dev/null 2>&1; then
        log_err "В конфиге нет inbound reality-in. Сначала install-server1.sh"
        exit 1
    fi

    if jq -e '.inbounds[] | select(.tag == "reality-mobile")' "${CONFIG_FILE}" >/dev/null 2>&1; then
        log_warn "Inbound reality-mobile уже есть — обновляю параметры клиента."
    else
        set_whitelist_dest
        backup_config

        local clients short_ids private_key
        clients=$(jq -c '.inbounds[] | select(.tag == "reality-in") | .settings.clients' "${CONFIG_FILE}")
        short_ids=$(jq -c '.inbounds[] | select(.tag == "reality-in") | .streamSettings.realitySettings.shortIds' "${CONFIG_FILE}")
        private_key=$(jq -r '.inbounds[] | select(.tag == "reality-in") | .streamSettings.realitySettings.privateKey // .streamSettings.realitySettings.privateKey' "${CONFIG_FILE}")

        local tmp
        tmp=$(mktemp)
        jq \
            --argjson port "${WHITELIST_PORT}" \
            --arg dest "${WL_DEST}" \
            --argjson sni "${WL_SNI}" \
            --arg pk "${private_key}" \
            --argjson sids "${short_ids}" \
            --argjson clients "${clients}" \
            '
            .inbounds += [{
              "port": ($port | tonumber),
              "listen": "0.0.0.0",
              "protocol": "vless",
              "settings": {
                "clients": $clients,
                "decryption": "none"
              },
              "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                  "dest": $dest,
                  "serverNames": $sni,
                  "privateKey": $pk,
                  "shortIds": $sids
                }
              },
              "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
              },
              "tag": "reality-mobile"
            }]
            ' "${CONFIG_FILE}" > "${tmp}"
        mv "${tmp}" "${CONFIG_FILE}"
        chmod 600 "${CONFIG_FILE}"

        log_info "Добавлен inbound reality-mobile :${WHITELIST_PORT} → dest ${WL_DEST}"
    fi

    set_whitelist_dest
    validate_xray_config
    restart_xray
    setup_ufw_ports "${WHITELIST_PORT}"

    local external_ip
    external_ip=$(get_external_ip)
    local public_key
    public_key=$("${INSTALL_DIR}/xray" x25519 -i "$(jq -r '.inbounds[] | select(.tag == "reality-in") | .streamSettings.realitySettings.privateKey' "${CONFIG_FILE}" | head -1)" 2>&1 | grep -iE "Password:" | sed 's/.*Password: *//i' | tr -d '\r\n')

    local clients_arr sids_arr
    clients_arr=$(jq -c '.inbounds[] | select(.tag == "reality-in") | .settings.clients' "${CONFIG_FILE}")
    sids_arr=$(jq -c '.inbounds[] | select(.tag == "reality-in") | .streamSettings.realitySettings.shortIds' "${CONFIG_FILE}")
    local first_sni
    first_sni=$(echo "${WL_SNI}" | jq -r '.[0]')

    local mobile_params="${CONFIG_DIR}/reality-client-params-mobile.json"
    jq -n \
        --arg host "${external_ip}" \
        --argjson port "${WHITELIST_PORT}" \
        --arg pk "${public_key}" \
        --arg fp "${WL_FP}" \
        --arg sni "${first_sni}" \
        --argjson sids "${sids_arr}" \
        --argjson users "${clients_arr}" \
        --arg preset "${WHITELIST_PRESET}" \
        --arg dest "${WL_DEST}" \
        '{
          role: "server1-mobile-whitelist",
          preset: $preset,
          dest: $dest,
          serverHost: $host,
          serverPort: ($port | tonumber),
          publicKey: $pk,
          fingerprint: $fp,
          serverName: $sni,
          shortIds: $sids,
          users: $users,
          note: "Профиль для мобильного интернета с белыми списками оператора"
        }' > "${mobile_params}"
    chmod 600 "${mobile_params}"

    echo ""
    echo "=============================================="
    log_info "Мобильный профиль (белые списки) включён."
    echo "=============================================="
    echo "  Порт:     ${WHITELIST_PORT}"
    echo "  Preset:   ${WHITELIST_PRESET} (${WL_DEST})"
    echo "  SNI:      ${first_sni}"
    echo "  Fingerprint: ${WL_FP}"
    echo "  Файл:     ${mobile_params}"
    echo ""
    echo "На Mac сгенерируйте ссылку:"
    echo "  python3 client/reality-link-gen.py ${mobile_params} --link --qr --tag VPN-Mobile-Whitelist"
    echo ""
    echo "В приложении: отдельный профиль для мобильной сети, Wi‑Fi — основной :443."
    echo "Если не помогло — см. dual-server/WHITELIST_MOBILE.md (блокировка по IP VPS)."
    echo "=============================================="
}

main "$@"
