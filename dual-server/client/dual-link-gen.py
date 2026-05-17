#!/usr/bin/env python3
"""
Генератор ссылок для двухсерверной схемы VPN-XRAY:
  — основной профиль: сервер 1 (split RU / abroad)
  — резервный профиль: сервер 2 (полный выход за рубежом)
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
from pathlib import Path

_client_dir = Path(__file__).resolve().parents[2] / "client"
_spec = importlib.util.spec_from_file_location(
    "reality_link_gen", _client_dir / "reality-link-gen.py"
)
_mod = importlib.util.module_from_spec(_spec)
assert _spec and _spec.loader
_spec.loader.exec_module(_mod)

build_vless_link = _mod.build_vless_link
export_v2ray_json = _mod.export_v2ray_json
load_server_params = _mod.load_server_params
print_qr = _mod.print_qr
validate_link = _mod.validate_link


def profile_from_params(data: dict, tag: str) -> tuple[str, dict]:
    users = data.get("users", [])
    sids = data.get("shortIds", [])
    if not users or not sids:
        raise ValueError(f"Нет users/shortIds в профиле {tag}")
    link = build_vless_link(
        uuid=users[0]["id"],
        host=data["serverHost"],
        port=int(data.get("serverPort", 443)),
        public_key=data["publicKey"],
        short_id=sids[0],
        server_name=data.get("serverName", ""),
        fingerprint=data.get("fingerprint", "chrome"),
        tag=tag,
    )
    meta = {
        "uuid": users[0]["id"],
        "host": data["serverHost"],
        "port": int(data.get("serverPort", 443)),
        "public_key": data["publicKey"],
        "short_id": sids[0],
        "server_name": data.get("serverName", ""),
        "fingerprint": data.get("fingerprint", "chrome"),
        "tag": tag,
    }
    return link, meta


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Ссылки vless: сервер 1 (основной) + сервер 2 (резерв)"
    )
    parser.add_argument("server1_params", help="reality-client-params.json с сервера 1")
    parser.add_argument(
        "server2_params",
        nargs="?",
        help="reality-client-params.json с сервера 2",
    )
    parser.add_argument("--qr", action="store_true", help="QR основного профиля")
    parser.add_argument("--json-bundle", action="store_true", help="JSON с двумя outbound")
    args = parser.parse_args()

    p1 = load_server_params(args.server1_params)
    link1, meta1 = profile_from_params(p1, "VPN-Server1-RU-split")

    print("=== Основной (сервер 1): RU — локально, остальное — через сервер 2 ===")
    print(link1)
    ok, msg = validate_link(link1)
    print(f"Валидация: {'OK' if ok else msg}\n")

    meta2 = None
    if args.server2_params and Path(args.server2_params).is_file():
        p2 = load_server_params(args.server2_params)
        link2, meta2 = profile_from_params(p2, "VPN-Server2-Fallback")
        print("=== Резерв (сервер 2): весь трафик за рубежом ===")
        print(link2)
        ok2, msg2 = validate_link(link2)
        print(f"Валидация: {'OK' if ok2 else msg2}\n")
    else:
        print("(Добавьте путь к server2_params для резервной ссылки)\n")

    if args.qr:
        print("--- QR: основной ---")
        print_qr(link1)

    if args.json_bundle and meta2:
        bundle = {
            "remarks": "VPN-XRAY dual",
            "profiles": [
                export_v2ray_json(**meta1),
                export_v2ray_json(**meta2),
            ],
        }
        print(json.dumps(bundle, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
