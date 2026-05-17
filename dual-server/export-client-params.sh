#!/usr/bin/env bash
# Создать reality-client-params.json из уже существующего config.json (после install).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

check_root
require_xray_installed
command -v jq &>/dev/null || { install_deps; }

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_err "Нет ${CONFIG_FILE}"
    exit 1
fi

PRIVATE_KEY=$(jq -r '.inbounds[] | select(.tag=="reality-in") | .streamSettings.realitySettings.privateKey // .streamSettings.realitySettings.privateKey' "${CONFIG_FILE}" | head -1)
PORT=$(jq -r '.inbounds[] | select(.tag=="reality-in") | .port' "${CONFIG_FILE}" | head -1)
SHORT_IDS=$(jq -c '.inbounds[] | select(.tag=="reality-in") | .streamSettings.realitySettings.shortIds' "${CONFIG_FILE}" | head -1)
USERS=$(jq -c '.inbounds[] | select(.tag=="reality-in") | .settings.clients' "${CONFIG_FILE}" | head -1)
SNI=$(jq -r '.inbounds[] | select(.tag=="reality-in") | .streamSettings.realitySettings.serverNames[0]' "${CONFIG_FILE}" | head -1)
FP="${FINGERPRINT:-chrome}"

[[ -n "${PRIVATE_KEY}" && "${PRIVATE_KEY}" != "null" ]] || {
    log_err "В config.json не найден privateKey REALITY"
    exit 1
}

log_info "Получение публичного ключа из privateKey..."
KEY_OUT=$("${INSTALL_DIR}/xray" x25519 -i "${PRIVATE_KEY}" 2>&1) || true
PUBLIC_KEY=$(echo "${KEY_OUT}" | grep -iE "Password:" | sed 's/.*Password: *//i' | tr -d '\r\n')
[[ -z "${PUBLIC_KEY}" ]] && PUBLIC_KEY=$(echo "${KEY_OUT}" | grep -i "Public key" | sed 's/.*: *//' | tr -d '\r\n')
[[ -n "${PUBLIC_KEY}" ]] || {
    log_err "Не удалось получить public key. Вывод xray:"
    echo "${KEY_OUT}"
    exit 1
}

EXTERNAL_IP=$(get_external_ip)
SERVER2_HOST=""
[[ -f "${CONFIG_DIR}/relay-server1-params.json" ]] && \
    SERVER2_HOST=$(jq -r '.server2Host // empty' "${CONFIG_DIR}/relay-server1-params.json")

CLIENT_INFO="${CONFIG_DIR}/reality-client-params.json"
jq -n \
    --arg host "${EXTERNAL_IP}" \
    --argjson port "${PORT}" \
    --arg pk "${PUBLIC_KEY}" \
    --arg fp "${FP}" \
    --arg sni "${SNI}" \
    --argjson sids "${SHORT_IDS}" \
    --argjson users "${USERS}" \
    --arg role "server1-primary" \
    --arg s2 "${SERVER2_HOST}" \
    '{
      role: $role,
      serverHost: $host,
      serverPort: ($port | tonumber),
      publicKey: $pk,
      fingerprint: $fp,
      serverName: $sni,
      shortIds: $sids,
      users: $users,
      server2Host: ($s2 | select(length > 0))
    }' > "${CLIENT_INFO}"

chmod 600 "${CLIENT_INFO}"
log_info "Создан: ${CLIENT_INFO}"
cat "${CLIENT_INFO}"
