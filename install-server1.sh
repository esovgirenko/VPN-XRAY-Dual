#!/usr/bin/env bash
# Обёртка: запуск из корня репозитория → dual-server/install-server1.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${ROOT}/dual-server/install-server1.sh" "$@"
