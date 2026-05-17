#!/usr/bin/env bash
# Смена порта Xray REALITY (config.json + reality-client-params.json + UFW).
# Запуск: sudo bash server/change-port.sh 8443

set -e
CONFIG_DIR="${CONFIG_DIR:-/usr/local/etc/xray}"
CONFIG_FILE="${CONFIG_DIR}/config.json"
CLIENT_PARAMS="${CONFIG_DIR}/reality-client-params.json"

[[ $EUID -eq 0 ]] || { echo "Запустите с sudo"; exit 1; }
NEW_PORT="${1:-}"
if [[ -z "${NEW_PORT}" || ! "${NEW_PORT}" =~ ^[0-9]+$ ]] || [[ "${NEW_PORT}" -lt 1 || "${NEW_PORT}" -gt 65535 ]]; then
    echo "Использование: sudo bash server/change-port.sh <ПОРТ>"
    echo "Пример: sudo bash server/change-port.sh 8443"
    echo "Рекомендуемые порты: 8443, 2053, 2083, 2087, 2096"
    exit 1
fi

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "Не найден ${CONFIG_FILE}. Сначала выполните install-reality.sh."
    exit 1
fi

OLD_PORT=$(jq -r '.inbounds[0].port' "${CONFIG_FILE}" 2>/dev/null)
[[ -z "${OLD_PORT}" || "${OLD_PORT}" == "null" ]] && OLD_PORT="443"
echo "Текущий порт: ${OLD_PORT}, новый порт: ${NEW_PORT}"

# Меняем порт в config.json
jq --argjson p "${NEW_PORT}" '.inbounds[0].port = $p' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
echo "[OK] config.json обновлён."

# Меняем порт в reality-client-params.json (для клиентов)
if [[ -f "${CLIENT_PARAMS}" ]]; then
    jq --argjson p "${NEW_PORT}" '.serverPort = $p' "${CLIENT_PARAMS}" > "${CLIENT_PARAMS}.tmp" && mv "${CLIENT_PARAMS}.tmp" "${CLIENT_PARAMS}"
    echo "[OK] reality-client-params.json обновлён."
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

# UFW
if command -v ufw &>/dev/null; then
    ufw allow "${NEW_PORT}/tcp" 2>/dev/null || true
    if [[ "${OLD_PORT}" != "${NEW_PORT}" ]] && [[ "${OLD_PORT}" =~ ^[0-9]+$ ]]; then
        ufw delete allow "${OLD_PORT}/tcp" 2>/dev/null || true
    fi
    echo "[OK] UFW: открыт ${NEW_PORT}/tcp."
fi

echo ""
echo "Готово. Порт изменён на ${NEW_PORT}."
echo "Обновите профиль на iPhone: сгенерируйте новую ссылку и переподключитесь:"
echo "  cp ${CLIENT_PARAMS} /opt/VPN-XRAY/client/ && cd /opt/VPN-XRAY/client && .venv/bin/python reality-link-gen.py reality-client-params.json --qr"
echo "  (или отсканируйте новый QR / вставьте новую ссылку в Shadowrocket)"
