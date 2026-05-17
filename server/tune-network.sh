#!/usr/bin/env bash
# Настройка ядра для лучшей скорости VPN (BBR, буферы).
# Запуск: sudo bash server/tune-network.sh

set -e
[[ $EUID -eq 0 ]] || { echo "Запустите с sudo"; exit 1; }

echo "[*] Включаем BBR и настраиваем сеть..."

# BBR — алгоритм контроля перегрузки, часто даёт прирост на каналах с потерей пакетов
if ! sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null | grep -q bbr; then
    cat >> /etc/sysctl.d/99-vpn-xray.conf << 'EOF'
# BBR и буферы для VPN
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
EOF
    sysctl -p /etc/sysctl.d/99-vpn-xray.conf 2>/dev/null || true
    echo "[OK] BBR включён (перезагрузка не требуется)."
else
    echo "[OK] BBR уже включён."
fi

echo ""
echo "Текущие значения:"
sysctl net.ipv4.tcp_congestion_control net.core.default_qdisc 2>/dev/null || true
echo ""
echo "Готово. Проверьте скорость с iPhone снова (Speedtest)."
