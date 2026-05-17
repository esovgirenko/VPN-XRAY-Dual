#!/usr/bin/env bash
# Восстановить relay-server1-params.json из текущего config.json (если relay-in уже есть).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

check_root
require_xray_installed

RELAY_UUID=$(jq -r '.inbounds[] | select(.tag=="relay-in") | .settings.clients[0].id' "${CONFIG_FILE}")
RELAY_PORT=$(jq -r '.inbounds[] | select(.tag=="relay-in") | .port' "${CONFIG_FILE}")

[[ -n "${RELAY_UUID}" && "${RELAY_UUID}" != "null" ]] || {
    log_err "В конфиге нет inbound relay-in. Сначала: sudo ./patch-server2.sh"
    exit 1
}

write_relay_params() {
    local relay_uuid="$1"
    local external_ip
    external_ip=$(get_external_ip)
    jq -n \
        --arg host "${external_ip}" \
        --argjson port "${RELAY_PORT}" \
        --arg uuid "${relay_uuid}" \
        --arg sni "vpn-relay.internal" \
        '{
          server2Host: $host,
          relayPort: ($port | tonumber),
          relayUuid: $uuid,
          relaySni: $sni
        }' > "${CONFIG_DIR}/relay-server1-params.json"
    chmod 600 "${CONFIG_DIR}/relay-server1-params.json"
    log_info "Записано: ${CONFIG_DIR}/relay-server1-params.json"
    cat "${CONFIG_DIR}/relay-server1-params.json"
}

# shellcheck disable=SC2120
write_relay_params "${RELAY_UUID}"
