#!/usr/bin/env python3
"""
VPN-XRAY: Генератор конфигураций и ссылок vless:// для протокола REALITY.
Поддержка экспорта в JSON (v2rayN/v2rayNG), QR-код и человекочитаемый текст.
"""

from __future__ import annotations

import argparse
import json
import sys
from base64 import urlsafe_b64encode
from pathlib import Path
from uuid import UUID, uuid4

try:
    import qrcode
    HAS_QR = True
except ImportError:
    HAS_QR = False

# UUID v5 namespace (DNS) для генерации стабильных UUID по имени пользователя
UUID_NS_DNS = UUID("6ba7b810-9dad-11d1-80b4-00c04fd430c8")

VALID_FINGERPRINTS = ("chrome", "firefox", "safari", "ios", "android")


def uuid_v5_from_name(name: str) -> str:
    """Генерация UUID v5 по имени пользователя (детерминированно)."""
    from uuid import uuid5
    return str(uuid5(UUID_NS_DNS, name))


def build_vless_link(
    uuid: str,
    host: str,
    port: int,
    *,
    public_key: str,
    short_id: str,
    server_name: str,
    fingerprint: str = "chrome",
    flow: str = "xtls-rprx-vision",
    tag: str = "REALITY",
) -> str:
    """
    Собирает ссылку vless:// с параметрами REALITY.
    Формат: vless://UUID@HOST:PORT?type=tcp&security=reality&pbk=...&fp=...&sni=...&sid=...&flow=...#TAG
    """
    params = {
        "type": "tcp",
        "security": "reality",
        "pbk": public_key,
        "fp": fingerprint,
        "sni": server_name,
        "sid": short_id,
        "flow": flow,
    }
    # spx (spider X) — путь для первого запроса; часто пустой или / для dest с IP
    if server_name:
        params["spx"] = "/"
    query = "&".join(f"{k}={_vless_quote(str(v))}" for k, v in params.items())
    link = f"vless://{uuid}@{host}:{port}?{query}#{_vless_quote(tag)}"
    return link


def _vless_quote(s: str) -> str:
    """URL-кодирование для vless (специфичные символы)."""
    try:
        from urllib.parse import quote
        return quote(s, safe="")
    except Exception:
        return s.replace(" ", "%20").replace("#", "%23").replace("&", "%26").replace("=", "%3D")


def validate_uuid(s: str) -> bool:
    try:
        UUID(s)
        return True
    except (ValueError, TypeError):
        return False


def validate_link(link: str) -> tuple[bool, str]:
    """Проверяет корректность сгенерированной ссылки vless."""
    if not link.startswith("vless://"):
        return False, "Ссылка должна начинаться с vless://"
    try:
        rest = link[8:]
        uuid_part, rest = rest.split("@", 1)
        if not validate_uuid(uuid_part):
            return False, "Некорректный UUID"
        host_port, query = rest.split("?", 1)
        host, port_s = host_port.rsplit(":", 1)
        port = int(port_s)
        if not (1 <= port <= 65535):
            return False, "Порт вне диапазона"
        if "#" in query:
            query = query.split("#", 1)[0]
        required = ("security=reality", "pbk=", "fp=", "sni=", "sid=", "flow=")
        for r in required:
            if r not in query:
                return False, f"Отсутствует параметр: {r}"
        return True, "OK"
    except Exception as e:
        return False, str(e)


def export_v2ray_json(
    uuid: str,
    host: str,
    port: int,
    public_key: str,
    short_id: str,
    server_name: str,
    fingerprint: str = "chrome",
    tag: str = "REALITY",
) -> dict:
    """Экспорт в формат v2rayN / v2rayNG (один outbound)."""
    return {
        "protocol": "vless",
        "settings": {
            "vnext": [
                {
                    "address": host,
                    "port": port,
                    "users": [
                        {
                            "id": uuid,
                            "encryption": "none",
                            "flow": "xtls-rprx-vision",
                        }
                    ],
                }
            ]
        },
        "streamSettings": {
            "network": "tcp",
            "security": "reality",
            "realitySettings": {
                "fingerprint": fingerprint,
                "serverName": server_name,
                "publicKey": public_key,
                "shortId": short_id,
            },
        },
        "tag": tag,
    }


def export_full_client_config(
    uuid: str,
    host: str,
    port: int,
    public_key: str,
    short_id: str,
    server_name: str,
    fingerprint: str = "chrome",
    socks_port: int = 10808,
) -> dict:
    """Полная клиентская конфигурация (inbounds SOCKS + outbound VLESS REALITY)."""
    return {
        "log": {"loglevel": "warning"},
        "inbounds": [
            {
                "listen": "127.0.0.1",
                "port": socks_port,
                "protocol": "socks",
                "settings": {"udp": True},
                "sniffing": {
                    "enabled": True,
                    "destOverride": ["http", "tls", "quic"],
                },
            }
        ],
        "outbounds": [
            {
                "protocol": "vless",
                "settings": {
                    "vnext": [
                        {
                            "address": host,
                            "port": port,
                            "users": [
                                {
                                    "id": uuid,
                                    "encryption": "none",
                                    "flow": "xtls-rprx-vision",
                                }
                            ],
                        }
                    ]
                },
                "streamSettings": {
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": {
                        "fingerprint": fingerprint,
                        "serverName": server_name,
                        "publicKey": public_key,
                        "shortId": short_id,
                    },
                },
                "tag": "proxy",
            }
        ],
    }


def print_qr(link: str) -> None:
    """Вывод QR-кода в терминал (если доступен qrcode)."""
    if not HAS_QR:
        print("Установите qrcode: pip install qrcode[pil]", file=sys.stderr)
        return
    qr = qrcode.QRCode(box_size=1, border=2)
    qr.add_data(link)
    qr.make(fit=True)
    qr.print_ascii(invert=True)


def human_readable(
    link: str,
    uuid: str,
    host: str,
    port: int,
    server_name: str,
    fingerprint: str,
    short_id: str,
) -> None:
    """Человекочитаемый вывод с пояснением параметров."""
    print("\n--- Параметры подключения (REALITY) ---")
    print(f"  UUID:         {uuid}")
    print(f"  Сервер:       {host}:{port}")
    print(f"  SNI (serverName): {server_name}")
    print(f"  Fingerprint:  {fingerprint}")
    print(f"  Short ID:     {short_id}")
    print(f"  Flow:         xtls-rprx-vision")
    print("\n--- Ссылка vless ---")
    print(link)
    print()


def load_server_params(path: str) -> dict:
    """Загрузка reality-client-params.json с сервера."""
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Генератор vless-ссылок и конфигов для Xray REALITY"
    )
    parser.add_argument(
        "input",
        nargs="?",
        help="Файл reality-client-params.json с сервера или ручной ввод",
    )
    parser.add_argument("--host", help="IP или домен сервера")
    parser.add_argument("--port", type=int, default=443, help="Порт (по умолчанию 443)")
    parser.add_argument("--uuid", help="UUID пользователя (если не из файла)")
    parser.add_argument("--short-id", dest="short_id", help="ShortId (4–16 hex-символов)")
    parser.add_argument("--public-key", dest="public_key", help="Публичный ключ x25519")
    parser.add_argument("--server-name", dest="server_name", help="SNI (serverName)")
    parser.add_argument(
        "--fingerprint",
        default="chrome",
        choices=VALID_FINGERPRINTS,
        help="Отпечаток TLS (по умолчанию chrome)",
    )
    parser.add_argument("--tag", default="REALITY", help="Имя подключения в клиенте")
    parser.add_argument("--name", help="Имя пользователя для генерации UUID v5 (опционально)")

    out = parser.add_argument_group("Вывод")
    out.add_argument("--link", action="store_true", help="Вывести только ссылку vless")
    out.add_argument("--json", action="store_true", help="Экспорт outbound в JSON (v2rayN/NG)")
    out.add_argument("--full-config", action="store_true", help="Полная клиентская конфигурация JSON")
    out.add_argument("--qr", action="store_true", help="Показать QR-код")
    out.add_argument("--text", action="store_true", help="Человекочитаемый текст с параметрами")
    out.add_argument("--validate", action="store_true", help="Проверить сгенерированную ссылку")

    args = parser.parse_args()

    # Заполнение из файла сервера
    if args.input and Path(args.input).is_file():
        data = load_server_params(args.input)
        host = args.host or data.get("serverHost", "")
        port = args.port or data.get("serverPort", 443)
        public_key = args.public_key or data.get("publicKey", "")
        server_name = args.server_name or data.get("serverName", "")
        fingerprint = args.fingerprint or data.get("fingerprint", "chrome")
        short_ids = data.get("shortIds", [])
        users = data.get("users", [])
        if not short_ids or not users:
            print("В файле должны быть shortIds и users.", file=sys.stderr)
            sys.exit(1)
        # Берём первого пользователя и первый shortId (или по индексу)
        uuid = args.uuid or users[0].get("id", "")
        short_id = args.short_id or short_ids[0]
    else:
        host = args.host or ""
        port = args.port or 443
        uuid = args.uuid or (uuid_v5_from_name(args.name) if args.name else str(uuid4()))
        short_id = args.short_id or "0123456789abcdef"[:8]
        public_key = args.public_key or ""
        server_name = args.server_name or "www.cloudflare.com"
        fingerprint = args.fingerprint or "chrome"

    if not all([host, public_key, uuid]):
        print("Задайте host, publicKey и uuid (или укажите файл reality-client-params.json).", file=sys.stderr)
        sys.exit(1)

    if fingerprint not in VALID_FINGERPRINTS:
        print(f"Fingerprint должен быть один из: {VALID_FINGERPRINTS}", file=sys.stderr)
        sys.exit(1)

    link = build_vless_link(
        uuid=uuid,
        host=host,
        port=port,
        public_key=public_key,
        short_id=short_id,
        server_name=server_name,
        fingerprint=fingerprint,
        tag=args.tag,
    )

    if args.validate:
        ok, msg = validate_link(link)
        print(f"Валидация: {'OK' if ok else 'Ошибка'} — {msg}")
        sys.exit(0 if ok else 1)

    if args.link:
        print(link)
    if args.json:
        obj = export_v2ray_json(uuid, host, port, public_key, short_id, server_name, fingerprint, args.tag)
        print(json.dumps(obj, ensure_ascii=False, indent=2))
    if args.full_config:
        obj = export_full_client_config(uuid, host, port, public_key, short_id, server_name, fingerprint)
        print(json.dumps(obj, ensure_ascii=False, indent=2))
    if args.qr:
        print_qr(link)
    if args.text:
        human_readable(link, uuid, host, port, server_name, fingerprint, short_id)

    if not any([args.link, args.json, args.full_config, args.qr, args.text]):
        # По умолчанию — ссылка и краткая справка
        print(link)
        print("\nОпции: --json, --full-config, --qr, --text, --validate", file=sys.stderr)


if __name__ == "__main__":
    main()
