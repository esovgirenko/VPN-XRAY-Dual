#!/usr/bin/env bash
# Смена dest и serverNames (под какой сервис маскируется REALITY).
# Запуск: sudo bash server/change-dest.sh "dns.google:443" "dns.google,google.com"
# Или интерактивно: sudo bash server/change-dest.sh

set -e
CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/xray}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENT_PARAMS="${CONFIG_DIR}/reality-client-params.json"

[[ $EUID -eq 0 ]] || { echo "Запустите с sudo"; exit 1; }

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Не найден ${CONFIG_FILE}. Сначала выполните install-reality.sh."
    exit 1
fi

# Текущие значения (v26 использует target, старые — dest)
CUR_DEST=$(jq -r '.inbounds[0].streamSettings.realitySettings.target // .inbounds[0].streamSettings.realitySettings.dest' "${CONFIG_FILE}" 2>/dev/null)
CUR_SN=$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames | join(", ")' "${CONFIG_FILE}" 2>/dev/null)
echo "Текущий dest: ${CUR_DEST}"
echo "Текущие serverNames: ${CUR_SN}"
echo ""

# Параметры: из аргументов или запрос
NEW_DEST="${1:-}"
NEW_SN_CSV="${2:-}"

if [[ -z "${NEW_DEST}" ]]; then
    read -rp "Новый dest (например dns.google:443 или www.google.com:443): " NEW_DEST
fi
if [[ -z "${NEW_SN_CSV}" ]]; then
    read -rp "serverNames через запятую (SNI из сертификата dest, например dns.google,google.com): " NEW_SN_CSV
fi

[[ -z "${NEW_DEST}" ]] && { echo "dest не задан."; exit 1; }
[[ -z "${NEW_SN_CSV}" ]] && { echo "serverNames не заданы."; exit 1; }

# Преобразуем serverNames в JSON-массив: "a,b,c" -> ["a","b","c"]
SERVER_NAMES_JSON=$(echo "${NEW_SN_CSV}" | jq -R 'split(",") | map(gsub("^ +| +$";"")) | map(select(length>0))')
FIRST_SN=$(echo "${NEW_SN_CSV}" | cut -d',' -f1 | tr -d ' ')

echo "Новый dest: ${NEW_DEST}"
echo "Новые serverNames: ${SERVER_NAMES_JSON}"
echo ""

# Обновляем config.json (v26: target; удаляем dest если был)
jq --arg d "${NEW_DEST}" --argjson sn "${SERVER_NAMES_JSON}" \
    'del(.inbounds[0].streamSettings.realitySettings.dest) | .inbounds[0].streamSettings.realitySettings.target = $d | .inbounds[0].streamSettings.realitySettings.serverNames = $sn' \
    "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
echo "[OK] config.json обновлён (target + serverNames)."

# Обновляем reality-client-params.json (клиентам нужен serverName для SNI)
if [[ -f "${CLIENT_PARAMS}" ]]; then
    jq --arg sn "${FIRST_SN}" '.serverName = $sn' "${CLIENT_PARAMS}" > "${CLIENT_PARAMS}.tmp" && mv "${CLIENT_PARAMS}.tmp" "${CLIENT_PARAMS}"
    echo "[OK] reality-client-params.json обновлён (serverName)."
fi

# Перезапуск Xray
systemctl restart xray
sleep 1
if systemctl is-active --quiet xray; then
    echo "[OK] Xray перезапущен."
else
    echo "[ОШИБКА] Xray не запустился. Проверьте: journalctl -u xray -n 30"
    exit 1
fi

echo ""
echo "Готово. Трафик теперь маскируется под: ${NEW_DEST} (SNI: ${FIRST_SN}, ...)."
echo "Обновите профиль на iPhone: заново сгенерируйте ссылку/QR и переподключитесь."
echo "  sudo cp ${CLIENT_PARAMS} /opt/VPN-XRAY/client/ && sudo chown proxyuser:proxyuser /opt/VPN-XRAY/client/reality-client-params.json"
echo "  cd /opt/VPN-XRAY/client && .venv/bin/python reality-link-gen.py reality-client-params.json --qr"
