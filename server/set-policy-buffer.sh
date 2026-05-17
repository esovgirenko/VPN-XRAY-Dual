#!/usr/bin/env bash
# Добавляет в config.json блок policy с bufferSize (в KB) для уровня 0.
# Влияет на буферизацию туннеля (не лимит скорости в Мбит/с).
# Запуск: sudo bash server/set-policy-buffer.sh [bufferSize_KB]
# Пример: sudo bash server/set-policy-buffer.sh 1024

set -e
CONFIG_FILE="/usr/local/etc/xray/config.json"
BUFFER_KB="${1:-1024}"

[[ $EUID -eq 0 ]] || { echo "Запустите с sudo"; exit 1; }
[[ -f "${CONFIG_FILE}" ]] || { echo "Не найден ${CONFIG_FILE}"; exit 1; }
[[ "${BUFFER_KB}" =~ ^[0-9]+$ ]] || { echo "Укажите bufferSize в KB (число), например 1024"; exit 1; }

# Добавить или обновить policy.levels."0".bufferSize
if jq -e '.policy.levels["0"]' "${CONFIG_FILE}" >/dev/null 2>&1; then
    jq --argjson buf "${BUFFER_KB}" '.policy.levels["0"].bufferSize = $buf' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
else
    # Нет policy — добавляем минимальный блок
    jq --argjson buf "${BUFFER_KB}" '. + {"policy": {"levels": {"0": {"handshake": 4, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5, "bufferSize": $buf}}}}' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
fi
echo "[OK] Установлен policy.levels.0.bufferSize = ${BUFFER_KB} KB"
systemctl restart xray
sleep 1
systemctl is-active --quiet xray && echo "[OK] Xray перезапущен." || { echo "Ошибка запуска Xray"; exit 1; }
