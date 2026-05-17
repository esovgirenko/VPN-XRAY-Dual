#!/usr/bin/env bash
# Создаёт виртуальное окружение и ставит зависимости (для Debian/Ubuntu с PEP 668)
set -e
cd "$(dirname "$0")"

# На Debian/Ubuntu для venv нужен пакет python3-venv
if ! python3 -c "import venv" 2>/dev/null; then
    echo "Установите python3-venv: sudo apt install python3-venv (или python3.12-venv)"
    exit 1
fi

python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
echo "Готово. Запуск: .venv/bin/python reality-link-gen.py ... или: source .venv/bin/activate && python reality-link-gen.py ..."
