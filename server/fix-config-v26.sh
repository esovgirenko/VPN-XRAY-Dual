#!/usr/bin/env bash
# Исправление config.json для Xray v26: fingerprint только у клиента; dest → target.
# Запуск: sudo bash server/fix-config-v26.sh

set -e
CONFIG_FILE="/usr/local/etc/xray/config.json"

[[ $EUID -eq 0 ]] || { echo "Запустите с sudo"; exit 1; }
[[ -f "${CONFIG_FILE}" ]] || { echo "Не найден ${CONFIG_FILE}"; exit 1; }

CHANGED=0
# 1) Удалить fingerprint из server realitySettings (в v26 только у клиента)
if jq -e '.inbounds[0].streamSettings.realitySettings.fingerprint' "${CONFIG_FILE}" >/dev/null 2>&1; then
    jq 'del(.inbounds[0].streamSettings.realitySettings.fingerprint)' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
    echo "[OK] Удалён fingerprint из realitySettings."
    CHANGED=1
fi
# 2) В v26 серверный REALITY ожидает "target" с непустым значением (host:port)
TARGET_VAL=$(jq -r '.inbounds[0].streamSettings.realitySettings.target // .inbounds[0].streamSettings.realitySettings.dest // empty' "${CONFIG_FILE}" 2>/dev/null | tr -d '\n\r ')
if [[ -z "${TARGET_VAL}" || "${TARGET_VAL}" == "null" ]]; then
    TARGET_VAL="www.cloudflare.com:443"
    echo "[WARN] target/dest пустой — подставляю ${TARGET_VAL}. При необходимости смените: sudo bash server/change-dest.sh \"${TARGET_VAL}\" \"www.cloudflare.com,cloudflare.com\""
fi
# Всегда записываем target (удаляем dest, если есть) и проверяем, что значение не пустое
CUR_TARGET=$(jq -r '.inbounds[0].streamSettings.realitySettings.target // empty' "${CONFIG_FILE}" 2>/dev/null | tr -d '\n\r ')
if [[ "${CUR_TARGET}" != "${TARGET_VAL}" || "${CUR_TARGET}" == "null" || -z "${CUR_TARGET}" ]]; then
    jq --arg t "${TARGET_VAL}" 'del(.inbounds[0].streamSettings.realitySettings.dest) | .inbounds[0].streamSettings.realitySettings.target = $t' "${CONFIG_FILE}" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "${CONFIG_FILE}"
    echo "[OK] Установлен target = ${TARGET_VAL}"
    CHANGED=1
fi

if [[ ${CHANGED} -eq 0 ]]; then
    echo "Изменений не требуется. Проверяю конфиг запуском Xray..."
fi

# Перезапуск и проверка
systemctl restart xray
sleep 2
if systemctl is-active --quiet xray; then
    echo "[OK] Xray запущен."
    exit 0
fi

# Если не запустился — выводим полный текст ошибки
echo "[ОШИБКА] Xray не запустился. Полный вывод:"
/usr/local/bin/xray run -config "${CONFIG_FILE}" 2>&1 || true
exit 1
