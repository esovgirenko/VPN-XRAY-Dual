#!/usr/bin/env bash
# Обёртка: запуск из корня репозитория → dual-server/patch-server2.sh
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${ROOT}/dual-server/patch-server2.sh" "$@"
