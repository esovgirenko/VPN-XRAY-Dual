{
  "log": {
    "loglevel": "error"
  },
  "inbounds": [
    {
      "port": {{PORT}},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": {{CLIENTS_JSON}},
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "{{DEST}}",
          "serverNames": {{SERVER_NAMES_JSON}},
          "privateKey": "{{PRIVATE_KEY}}",
          "shortIds": {{SHORT_IDS_JSON}},
          "fingerprint": "{{FINGERPRINT}}"
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
