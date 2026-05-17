#!/usr/bin/env bash
# =============================================================================
# VPN-XRAY: Установка Xray-core с протоколом REALITY на Ubuntu 22.04 / Debian 12
# Автоматическая генерация конфигурации, x25519-ключей и настройка systemd/UFW
# =============================================================================

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Актуальная версия: Xray-core перешёл на нумерацию v26.x (v1.8.x больше не доступна)
readonly XRAY_VERSION="${XRAY_VERSION:-26.2.6}"
readonly XRAY_ARCH="$(uname -m)"
readonly INSTALL_DIR="/usr/local/bin"
readonly CONFIG_DIR="/usr/local/etc/xray"
readonly CONFIG_FILE="${CONFIG_DIR}/config.json"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERR]${NC} $*"; }

# Маппинг архитектуры на имя файла Xray
get_xray_arch() {
    case "${XRAY_ARCH}" in
        x86_64)  echo "64";;
        aarch64|arm64) echo "arm64-v8a";;
        armv7l)   echo "arm32-v7a";;
        *)       log_err "Неподдерживаемая архитектура: ${XRAY_ARCH}"; exit 1;;
    esac
}

# Проверка прав root
check_root() {
    [[ $EUID -eq 0 ]] || { log_err "Запустите скрипт с правами root (sudo)."; exit 1; }
}

# Проверка конфликтующих сервисов на порту
check_port_conflict() {
    local port="${1:-443}"
    if command -v ss &>/dev/null; then
        if ss -tlnp | grep -q ":${port} "; then
            log_warn "Порт ${port} уже занят."
            ss -tlnp | grep ":${port} " || true
            if systemctl is-active --quiet nginx 2>/dev/null || systemctl is-active --quiet apache2 2>/dev/null; then
                log_warn "Обнаружен nginx или apache. Остановите их или выберите другой порт."
                read -rp "Продолжить всё равно? (y/N): " ans
                [[ "${ans,,}" == "y" ]] || exit 1
            fi
        fi
    fi
}

# Установка зависимостей
install_deps() {
    log_info "Установка зависимостей..."
    if command -v apt-get &>/dev/null; then
        apt-get update -qq
        apt-get install -y -qq curl ca-certificates jq unzip
    else
        log_err "Поддерживается только apt (Debian/Ubuntu)."; exit 1
    fi
}

# Скачивание и установка Xray с проверкой контрольной суммы
install_xray() {
    local arch_suffix
    arch_suffix=$(get_xray_arch)
    local url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${arch_suffix}.zip"
    local zip_file="/tmp/xray-${XRAY_VERSION}.zip"
    local sum_url="https://github.com/XTLS/Xray-core/releases/download/v${XRAY_VERSION}/Xray-linux-${arch_suffix}.zip.dgst"

    log_info "Скачивание Xray-core v${XRAY_VERSION} (это может занять минуту)..."
    if ! curl -fSL --progress-bar --connect-timeout 10 --max-time 300 -o "${zip_file}" "${url}"; then
        log_err "Не удалось скачать ${url}"
        log_err "Проверьте доступ к GitHub и версию: XRAY_VERSION=${XRAY_VERSION} (актуальная: 26.2.6)"
        exit 1
    fi

    if curl -fsSL -o /tmp/xray.dgst "${sum_url}" 2>/dev/null; then
        local dgst_file="/tmp/xray.dgst"
        if command -v sha256sum &>/dev/null; then
            local expected="" actual=""
            # Не выходить при отсутствии SHA256 в .dgst (формат файла может отличаться)
            expected=$(grep -i SHA256 "${dgst_file}" 2>/dev/null | awk '{print $NF}' | tr -d '\r\n' || true)
            actual=$(sha256sum "${zip_file}" | awk '{print $1}')
            if [[ -n "${expected}" && "${expected}" != "${actual}" ]]; then
                log_err "Контрольная сумма не совпадает. Ожидалось: ${expected}, получено: ${actual}"
                exit 1
            fi
            [[ -n "${expected}" ]] && log_info "Контрольная сумма SHA256 совпадает."
        fi
    else
        log_warn "Файл контрольной суммы недоступен, проверка пропущена."
    fi

    mkdir -p "${CONFIG_DIR}"
    rm -rf /tmp/xray-extract
    if ! unzip -o -q "${zip_file}" -d /tmp/xray-extract; then
        log_err "Ошибка распаковки. Проверьте: unzip -l ${zip_file}"
        exit 1
    fi
    local xray_bin
    xray_bin=$(find /tmp/xray-extract -maxdepth 2 -type f \( -name 'xray' -o -name 'Xray' \) 2>/dev/null | head -1)
    if [[ -z "${xray_bin}" || ! -x "${xray_bin}" ]]; then
        log_err "В архиве не найден исполняемый файл xray/Xray. Содержимое:"
        ls -laR /tmp/xray-extract 2>/dev/null || true
        exit 1
    fi
    cp -f "${xray_bin}" "${INSTALL_DIR}/xray"
    chmod +x "${INSTALL_DIR}/xray"
    rm -rf /tmp/xray-extract "${zip_file}" /tmp/xray.dgst 2>/dev/null
    log_info "Xray установлен в ${INSTALL_DIR}/xray"
}

# Генерация x25519 ключей через xray x25519
generate_x25519() {
    local out
    out=$("${INSTALL_DIR}/xray" x25519 2>/dev/null) || { log_err "Не удалось сгенерировать x25519 (проверьте версию Xray >= 1.7)"; exit 1; }
    echo "${out}"
}

# Определение внешнего IP
get_external_ip() {
    local ip
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip=$(curl -fsSL --max-time 5 "${url}" 2>/dev/null) && break
    done
    if [[ -z "${ip}" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "${ip}"
}

# Генерация shortId (4-8 байт = 8-16 hex символов, чётное количество)
generate_short_id() {
    local len="${1:-8}"
    len=$(( len * 2 ))
    [[ $len -lt 8 ]] && len=8
    [[ $len -gt 16 ]] && len=16
    head -c $(( len / 2 )) /dev/urandom | xxd -p -c 256 | tr -d '\n' | head -c "${len}"
}

# Генерация UUID (v4 для простоты на сервере; клиент может использовать uuid5)
generate_uuid() {
    "${INSTALL_DIR}/xray" uuid 2>/dev/null || uuidgen 2>/dev/null || ( cat /proc/sys/kernel/random/uuid 2>/dev/null ) || echo "00000000-0000-0000-0000-000000000000"
}

# Интерактивный ввод параметров
gather_config() {
    echo ""
    log_info "=== Параметры REALITY ==="

    read -rp "Порт (443 / 8443 / 2053) [443]: " PORT
    PORT="${PORT:-443}"
    if [[ ! "$PORT" =~ ^(443|8443|2053)$ ]]; then
        log_warn "Используется нестандартный порт: ${PORT}"
    fi
    check_port_conflict "${PORT}"

    log_info "Целевой dest — сервер, под который маскируем TLS (должен поддерживать TLS 1.3 и HTTP/2)."
    read -rp "dest (например www.cloudflare.com:443 или dns.google:443) [www.cloudflare.com:443]: " DEST
    DEST="${DEST:-www.cloudflare.com:443}"

    read -rp "serverNames через запятую (SNI из сертификата dest) [www.cloudflare.com,cloudflare.com]: " SNI_INPUT
    SNI_INPUT="${SNI_INPUT:-www.cloudflare.com,cloudflare.com}"
    IFS=',' read -ra SNI_ARR <<< "${SNI_INPUT}"
    SERVER_NAMES_JSON=$(printf '"%s",' "${SNI_ARR[@]}" | sed 's/,$//')
    SERVER_NAMES_JSON="[ ${SERVER_NAMES_JSON} ]"

    echo ""
    log_info "Доступные отпечатки: chrome, firefox, safari, ios, android"
    read -rp "Fingerprint [chrome]: " FINGERPRINT
    FINGERPRINT="${FINGERPRINT:-chrome}"

    read -rp "Количество пользователей (для генерации shortId) [1]: " NUSERS
    NUSERS="${NUSERS:-1}"
    SHORT_IDS="[]"
    CLIENT_JSON=""
    for ((i=0; i<NUSERS; i++)); do
        sid=$(generate_short_id 4)
        uuid=$(generate_uuid)
        SHORT_IDS=$(echo "${SHORT_IDS}" | jq --arg s "${sid}" '. + [$s]')
        if [[ $i -eq 0 ]]; then
            CLIENT_JSON="{\"id\": \"${uuid}\", \"flow\": \"xtls-rprx-vision\"}"
        else
            CLIENT_JSON="${CLIENT_JSON}, {\"id\": \"${uuid}\", \"flow\": \"xtls-rprx-vision\"}"
        fi
        echo "  Пользователь $((i+1)): UUID=${uuid}, shortId=${sid}"
    done
    CLIENT_JSON="[ ${CLIENT_JSON} ]"

    KEY_PAIR=$(generate_x25519)
    # Xray v26+: PrivateKey / Password (публичный ключ для клиента). Старый формат: Private key / Public key
    PRIVATE_KEY=$(echo "${KEY_PAIR}" | grep -iE "PrivateKey:" | sed 's/.*PrivateKey: *//i' | tr -d '\r\n')
    [[ -z "${PRIVATE_KEY}" ]] && PRIVATE_KEY=$(echo "${KEY_PAIR}" | grep -i "Private key" | sed 's/.*: *//' | tr -d '\r\n')
    PUBLIC_KEY=$(echo "${KEY_PAIR}" | grep -iE "Password:" | sed 's/.*Password: *//i' | tr -d '\r\n')
    [[ -z "${PUBLIC_KEY}" ]] && PUBLIC_KEY=$(echo "${KEY_PAIR}" | grep -i "Public key" | sed 's/.*: *//' | tr -d '\r\n')
    if [[ -z "${PRIVATE_KEY}" || -z "${PUBLIC_KEY}" ]]; then
        log_err "Не удалось распарсить вывод xray x25519. Вывод команды:"
        echo "${KEY_PAIR}" | head -5
        exit 1
    fi
    log_info "Сгенерированы x25519 ключи."

    EXTERNAL_IP=$(get_external_ip)
    log_info "Внешний IP сервера: ${EXTERNAL_IP}"

    # Лимит скорости (в байтах/с, 0 = без лимита). Можно задать через переменную окружения.
    UPLINK="${UPLINK:-0}"
    DOWNLINK="${DOWNLINK:-0}"
}

# Создание конфигурации Xray
write_config() {
    log_info "Запись конфигурации в ${CONFIG_FILE}..."
    mkdir -p "${CONFIG_DIR}"

    # policy system для ограничения скорости (если задано)
    local policy_block=""
    if [[ "${UPLINK}" -gt 0 || "${DOWNLINK}" -gt 0 ]]; then
        policy_block=', "policy": { "levels": { "0": { "handshake": 4, "connIdle": 300, "uplinkOnly": 2, "downlinkOnly": 5, "statsUserUplink": true, "statsUserDownlink": true, "bufferSize": 512 } }, "system": { "statsInboundUplink": true, "statsInboundDownlink": true } }'
    fi

    local stats_block=""
    if [[ "${UPLINK}" -gt 0 || "${DOWNLINK}" -gt 0 ]]; then
        stats_block=', "stats": {}'
    fi

    local api_block=""
    local level_stats=""
    if [[ "${UPLINK}" -gt 0 || "${DOWNLINK}" -gt 0 ]]; then
        api_block=', "api": { "tag": "api", "services": [ "HandlerService", "StatsService" ] }'
        level_stats='"statsUserUplink": true, "statsUserDownlink": true'
    fi

    cat > "${CONFIG_FILE}" << EOF
{
  "log": {
    "loglevel": "error"
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
          "target": "${DEST}",
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
    }
  ]
}
EOF

    # Сохраняем данные для клиента в отдельный файл (без privateKey)
    local client_info="${CONFIG_DIR}/reality-client-params.json"
    local first_sni
    first_sni=$(echo "${SERVER_NAMES_JSON}" | jq -r '.[0]' 2>/dev/null) || first_sni="${SNI_INPUT%%,*}"
    local short_ids_array
    short_ids_array=$(echo "${SHORT_IDS}" | jq -c '.' 2>/dev/null) || short_ids_array="[]"
    local clients_array
    clients_array=$(echo "${CLIENT_JSON}" | jq -c '.' 2>/dev/null) || clients_array="[]"
    if ! jq -n \
        --arg host "${EXTERNAL_IP}" \
        --arg port "${PORT}" \
        --arg pk "${PUBLIC_KEY}" \
        --arg fp "${FINGERPRINT}" \
        --arg sni "${first_sni}" \
        --argjson sids "${short_ids_array}" \
        --argjson users "${clients_array}" \
        '{ serverHost: $host, serverPort: ($port | tonumber), publicKey: $pk, fingerprint: $fp, serverName: $sni, shortIds: $sids, users: $users }' \
        > "${client_info}" 2>/dev/null; then
        log_warn "jq не записал client params, создаю упрощённый файл вручную."
        cat > "${client_info}" << CLIENTEOF
{
  "serverHost": "${EXTERNAL_IP}",
  "serverPort": ${PORT},
  "publicKey": "${PUBLIC_KEY}",
  "fingerprint": "${FINGERPRINT}",
  "serverName": "${first_sni}",
  "shortIds": ${SHORT_IDS},
  "users": ${CLIENT_JSON}
}
CLIENTEOF
    fi
    chmod 600 "${CONFIG_FILE}" "${client_info}" 2>/dev/null || true
    if [[ ! -s "${client_info}" ]]; then
        log_err "Не удалось создать ${client_info}"
        exit 1
    fi
    log_info "Параметры для клиента сохранены в ${client_info}"
}

# Установка systemd-сервиса
install_systemd() {
    log_info "Установка systemd-сервиса..."
    cat > /etc/systemd/system/xray.service << 'SVCEOF'
[Unit]
Description=Xray-core REALITY Service
Documentation=https://github.com/XTLS/Xray-core
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/xray run -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable xray
    systemctl restart xray
    sleep 1
    if systemctl is-active --quiet xray; then
        log_info "Сервис xray запущен и добавлен в автозагрузку."
    else
        log_err "Сервис xray не запустился. Проверьте: journalctl -u xray -n 50"
        exit 1
    fi
}

# Настройка UFW
setup_ufw() {
    if command -v ufw &>/dev/null; then
        log_info "Настройка UFW..."
        ufw allow "${PORT}/tcp" 2>/dev/null || true
        ufw allow 22/tcp 2>/dev/null || true
        echo "y" | ufw enable 2>/dev/null || true
        ufw status | head -20
    else
        log_warn "UFW не установлен. Откройте порт ${PORT}/tcp вручную."
    fi
}

# Вывод итоговой информации
print_summary() {
    local client_info="${CONFIG_DIR}/reality-client-params.json"
    echo ""
    echo "=============================================="
    log_info "Установка завершена."
    echo "=============================================="
    echo "Параметры для клиента (vless, reality):"
    echo "  Файл: ${client_info}"
    echo "  Используйте client/reality-link-gen.py с этим файлом для генерации ссылок и конфигов."
    echo "  Проверка: test/verify-tls.sh <IP_СЕРВЕРА> ${PORT} <SNI из serverNames>"
    echo ""
    log_warn "Для максимальной стойкости рекомендуется использовать свой домен с CDN (Cloudflare Proxy)."
    log_warn "Использование должно соответствовать законодательству вашей страны."
    echo "=============================================="
}

# Основной поток
main() {
    check_root
    install_deps
    install_xray
    gather_config
    write_config
    install_systemd
    setup_ufw
    print_summary
}

main "$@"
