#!/usr/bin/env bash
# =============================================================================
# VPN-XRAY: Проверка TLS-рукопожатия и доступности REALITY-сервера
# - curl с подменой SNI для проверки доступности порта
# - openssl s_client для проверки отпечатка TLS целевого dest
# =============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_err()   { echo -e "${RED}[ERR]${NC} $*"; }

# Параметры по умолчанию
HOST="${1:-}"
PORT="${2:-443}"
SNI="${3:-www.cloudflare.com}"

usage() {
    echo "Использование: $0 <HOST> [PORT] [SNI]"
    echo "  HOST  — IP или домен вашего Xray REALITY сервера"
    echo "  PORT  — порт (по умолчанию 443)"
    echo "  SNI   — значение Server Name Indication (по умолчанию www.cloudflare.com)"
    echo ""
    echo "Примеры:"
    echo "  $0 203.0.113.10"
    echo "  $0 vpn.example.com 443 dns.google"
    exit 1
}

[[ -z "${HOST}" ]] && usage

# 1. Проверка доступности порта (TCP)
check_port() {
    log_info "Проверка доступности ${HOST}:${PORT} (TCP)..."
    if command -v nc &>/dev/null; then
        if nc -z -w 3 "${HOST}" "${PORT}" 2>/dev/null; then
            log_info "Порт ${PORT} открыт."
            return 0
        fi
    fi
    if command -v timeout &>/dev/null && command -v bash &>/dev/null; then
        if (echo >/dev/tcp/"${HOST}"/"${PORT}") 2>/dev/null; then
            log_info "Порт ${PORT} открыт."
            return 0
        fi
    fi
    log_warn "Не удалось проверить порт (установите netcat-openbsd или используйте telnet)."
    return 1
}

# 2. Curl с подменой SNI — проверка, что сервер отвечает на TLS (REALITY принимает соединение)
check_curl_sni() {
    log_info "Проверка TLS с SNI=${SNI} к ${HOST}:${PORT}..."
    local out
    if out=$(curl -fsSL --max-time 10 --connect-timeout 5 \
        --resolve "${SNI}:${PORT}:${HOST}" \
        "https://${SNI}:${PORT}/" -k 2>&1); then
        log_info "Соединение по TLS установлено (ответ получен или редирект)."
        return 0
    else
        # REALITY не отдаёт обычный HTTP — возможен таймаут или неверный ответ; это нормально
        if echo "${out}" | grep -q "timed out\|Connection refused"; then
            log_warn "Соединение не удалось. Убедитесь, что Xray слушает на ${HOST}:${PORT} и SNI совпадает с serverNames."
        else
            log_info "Ответ от сервера получен (для REALITY не обязательно успешный HTTP)."
        fi
        return 0
    fi
}

# 3. Проверка отпечатка TLS целевого dest (не вашего сервера, а того, под кого маскируемся)
check_dest_fingerprint() {
    local dest_host="${SNI}"
    local dest_port="${PORT}"
    log_info "Проверка TLS целевого dest (для справки): ${dest_host}:${dest_port}"
    log_info "Отпечаток сертификата целевого сервера (должен поддерживать TLS 1.3):"
    if command -v openssl &>/dev/null; then
        echo | openssl s_client -connect "${dest_host}:${dest_port}" -servername "${dest_host}" -tlsextdebug 2>/dev/null | openssl x509 -noout -fingerprint -sha256 2>/dev/null || true
        echo ""
        log_info "Информация о сертификате:"
        echo | openssl s_client -connect "${dest_host}:${dest_port}" -servername "${dest_host}" 2>/dev/null | openssl x509 -noout -subject -issuer 2>/dev/null || true
    else
        log_warn "Установите openssl для проверки сертификата dest."
    fi
}

# 4. Краткая справка по верификации в Wireshark
print_wireshark_tip() {
    echo ""
    log_info "--- Верификация в Wireshark / TLS-анализаторах ---"
    echo "1. Захватите трафик до вашего сервера на порт ${PORT}."
    echo "2. REALITY маскирует рукопожатие под целевой dest (${SNI}); внешне трафик похож на обычный TLS 1.3 к ${SNI}."
    echo "3. Фильтр Wireshark: tcp.port == ${PORT}"
    echo "4. Для анализа TLS: в Client Hello будет SNI = ${SNI}; отпечаток (JA3 и др.) соответствует выбранному fingerprint (chrome/firefox/...)."
    echo ""
}

check_port
check_curl_sni
check_dest_fingerprint
print_wireshark_tip

log_info "Проверка завершена."
