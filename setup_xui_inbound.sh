#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Запустите от root"

DOMAIN="visualk-play.online"
SECRET_PATH="/updates/templates/assets/v3/conf"
CLIENT_UUID="fe4ab9ef-c336-4980-91b2-342102dc45ba"

# === 1. УСТАНОВКА ПАНЕЛИ ===
info "Устанавливаем панель 3x-ui v2.9.4..."
echo -e "n\nn\n4\ny" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) v2.9.4

# === 2. ОСТАНАВЛИВАЕМ ПАНЕЛЬ ===
info "Останавливаем панель..."
systemctl stop x-ui

# === 3. ПРИВЯЗЫВАЕМ К LOCALHOST ===
info "Привязываем панель к localhost..."
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';"

# === 4. ДОБАВЛЯЕМ INBOUND В config.json ===
info "Добавляем inbound в config.json..."

# Читаем текущий конфиг
CONFIG=$(cat /usr/local/x-ui/bin/config.json)

# Формируем новый inbound
INBOUND=$(cat <<EOF
{
  "tag": "xhttp-cascade",
  "listen": "127.0.0.1",
  "port": 10000,
  "protocol": "vless",
  "settings": {
    "clients": [
      {
        "id": "$CLIENT_UUID",
        "flow": ""
      }
    ],
    "decryption": "none"
  },
  "streamSettings": {
    "network": "xhttp",
    "xhttpSettings": {
      "path": "$SECRET_PATH",
      "host": "$DOMAIN",
      "mode": "packet-up",
      "scMaxBufferedPosts": 30,
      "scMaxEachPostBytes": "1000000-2000000",
      "noSSEHeader": false,
      "xPaddingBytes": "100-1000"
    },
    "sockopt": {
      "tcpFastOpen": false,
      "tcpNoDelay": true,
      "tcpMaxSeg": 1440,
      "tcpCongestion": "bbr",
      "tcpMptcp": false,
      "tcpKeepAliveIdle": 60,
      "tcpKeepAliveInterval": 30,
      "tcpUserTimeout": 10000,
      "tcpWindowClamp": 600
    }
  },
  "sniffing": {
    "enabled": true,
    "destOverride": ["http", "tls"],
    "routeOnly": true
  }
}
EOF
)

# Вставляем inbound в массив inbounds (после "api")
echo "$CONFIG" | jq ".inbounds += [$INBOUND]" > /usr/local/x-ui/bin/config.json

# === 5. ДОБАВЛЯЕМ INBOUND В БД (для отображения в интерфейсе) ===
sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds WHERE port = 10000;"
sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (remark, port, protocol, settings, stream_settings, sniffing, listen) VALUES (
    'xhttp-cascade',
    10000,
    'vless',
    '{\"clients\":[{\"id\":\"$CLIENT_UUID\",\"flow\":\"\"}],\"decryption\":\"none\"}',
    '$(echo "$INBOUND" | jq -c '.streamSettings' | sed "s/\"/\\\\\"/g")',
    '{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"],\"routeOnly\":true}',
    '127.0.0.1'
);"

# === 6. ЗАПУСКАЕМ ПАНЕЛЬ ===
systemctl start x-ui
sleep 3

# === 7. ПРОВЕРКА ===
if ss -tlnp | grep -q ":10000 "; then
    info "✅ Порт 10000 слушается — всё работает!"
else
    warning "❌ Порт 10000 не слушается."
fi
