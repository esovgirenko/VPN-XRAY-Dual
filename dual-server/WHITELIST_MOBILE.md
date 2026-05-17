# Мобильный интернет и «белые списки» оператора

На домашнем Wi‑Fi VPN работает, на мобильной сети — нет: типичная ситуация для ограничений российских операторов.

## Два типа фильтрации

| Тип | Что проверяет оператор | Помогает REALITY |
|-----|------------------------|------------------|
| **По SNI** | Имя в TLS ClientHello (`music.yandex.ru`, `vk.com`…) | Да — маскировка под разрешённый сайт |
| **По IP** | Адрес вашего VPS | Нет — соединение идёт на IP сервера, не на IP Яндекса/VK |

Если блокировка **по IP**, смена SNI не спасёт. Нужен VPS в подсети из [белого списка](https://github.com/hxehex/russia-mobile-internet-whitelist) (Яндекс.Облако, VK Cloud, часть хостингов РФ) или схема через CDN.

## Режим «Мобильный / белые списки»

Скрипт добавляет **второй профиль** на отдельном порту (по умолчанию **2053**) с SNI под сервисы из белых списков. Основной **:443** (Яндекс Музыка) для Wi‑Fi не меняется.

### На сервере 1 (friday)

```bash
cd ~/VPN-XRAY-Dual/dual-server
chmod +x enable-mobile-whitelist.sh
sudo ./enable-mobile-whitelist.sh --dest vk
```

Presets:

| `--dest` | Маскировка (dest) | Fingerprint |
|----------|-------------------|-------------|
| `vk` | `eh.vk.com:443` (по умолчанию) | `ios` |
| `yandex` | `music.yandex.ru:443` | `chrome` |
| `ozon` | `www.ozon.ru:443` | `chrome` |

**Firewall:** откройте **TCP 2053** в панели хостинга и UFW:

```bash
sudo ufw allow 2053/tcp
```

### Ссылка для телефона

```bash
# на сервере — скопировать JSON в домашнюю папку
sudo cp /usr/local/etc/xray/reality-client-params-mobile.json ~/
sudo chown $USER:$USER ~/reality-client-params-mobile.json

# на Mac
scp user@SERVER1:~/reality-client-params-mobile.json ./server1-mobile-params.json
cd VPN-XRAY-Dual/client
./setup-venv.sh
.venv/bin/python reality-link-gen.py ../server1-mobile-params.json --link --qr --tag VPN-Mobile-Whitelist
```

### Два профиля в приложении

| Профиль | Когда |
|---------|--------|
| **VPN-Server1-RU-split** (:443) | Домашний Wi‑Fi |
| **VPN-Mobile-Whitelist** (:2053) | Мобильная сеть |
| **VPN-Server2-Fallback** | Если сервер 1 недоступен |

## Если мобильный профиль всё равно не подключается

1. **Проверьте IP VPS** — есть ли подсеть в [russia-mobile-internet-whitelist](https://github.com/hxehex/russia-mobile-internet-whitelist).
2. **Смените preset:** `sudo ./enable-mobile-whitelist.sh --dest yandex` или `--dest ozon`.
3. **Попробуйте другой порт:** `--port 8443` (и откройте его в firewall).
4. **Резерв:** подключайтесь напрямую к **серверу 2** (зарубежный) — часто его IP не в белом списке РФ, но тогда весь трафик идёт за рубежом.
5. **Панель хостинга** — входящий TCP 2053 (и 443) на сервере 1.

## Проверка с телефона (LTE)

В логах сервера 1 при попытке подключения:

```bash
sudo journalctl -u xray -f
```

Должно появиться `accepted ... [reality-mobile -> ...]`. Если записей нет — блокировка до сервера (IP/firewall). Если есть `accepted`, но сайты не открываются — смотрите relay 8443 на сервер 2 (см. основной README).

## Юридическое предупреждение

Использование должно соответствовать законодательству вашей страны.
