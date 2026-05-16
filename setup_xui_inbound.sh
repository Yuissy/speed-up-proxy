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
info "Останавливаем панель для правок..."
systemctl stop x-ui

# === 3. ПРИВЯЗЫВАЕМ К LOCALHOST ===
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';"

# === 4. ПИШЕМ XRAY TEMPLATE С INBOUND'ОМ ===
info "Записываем xrayTemplateConfig с inbound..."

XRAY_TEMPLATE=$(cat <<XEOF
{
  "inbounds": [
    {
      "tag": "xhttp-cascade",
      "listen": "127.0.0.1",
      "port": 10000,
      "protocol": "vless",
      "settings": {
        "clients": [{"id": "$CLIENT_UUID", "flow": ""}],
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
  ]
}
XEOF
)

sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '$XRAY_TEMPLATE' WHERE key = 'xrayTemplateConfig';"

# === 5. ЗАПУСКАЕМ ПАНЕЛЬ ===
info "Запускаем панель..."
systemctl start x-ui
sleep 3

# === 6. ПРОВЕРКА ===
echo ""
if ss -tlnp | grep -q ":10000 "; then
    info "✅ Порт 10000 слушается!"
else
    warning "❌ Порт 10000 не слушается"
    grep -c "xhttp-cascade" /usr/local/x-ui/bin/config.json
fi
