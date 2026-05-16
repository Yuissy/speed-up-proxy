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

# === 2. ОСТАНАВЛИВАЕМ ПАНЕЛЬ И ПРИВЯЗЫВАЕМ К LOCALHOST ===
info "Останавливаем панель и привязываем к localhost..."
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';"

# === 3. ДОБАВЛЯЕМ INBOUND ЧЕРЕЗ БД ===
info "Добавляем inbound через БД..."

sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds WHERE port = 10000;"

sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (remark, port, protocol, settings, stream_settings, sniffing, listen) VALUES (
    'xhttp-cascade',
    10000,
    'vless',
    '{\"clients\":[{\"id\":\"$CLIENT_UUID\",\"flow\":\"\"}],\"decryption\":\"none\"}',
    '{\"network\":\"xhttp\",\"security\":\"none\",\"xhttpSettings\":{\"path\":\"$SECRET_PATH\",\"host\":\"$DOMAIN\",\"mode\":\"packet-up\",\"scMaxBufferedPosts\":30,\"scMaxEachPostBytes\":\"1000000-2000000\",\"noSSEHeader\":false,\"xPaddingBytes\":\"100-1000\"},\"sockopt\":{\"tcpFastOpen\":false,\"tcpNoDelay\":true,\"tcpMaxSeg\":1440,\"tcpCongestion\":\"bbr\",\"tcpMptcp\":false,\"tcpKeepAliveIdle\":60,\"tcpKeepAliveInterval\":30,\"tcpUserTimeout\":10000,\"tcpWindowClamp\":600}}',
    '{\"enabled\":true,\"destOverride\":[\"http\",\"tls\"],\"routeOnly\":true}',
    '127.0.0.1'
);"

# === 4. ПЕРЕСОБИРАЕМ КОНФИГ ===
info "Пересобираем config.json из БД..."
x-ui migrate

# === 5. ЗАПУСКАЕМ ПАНЕЛЬ ===
systemctl start x-ui
sleep 3

# === 6. ПРОВЕРКА ===
if ss -tlnp | grep -q ":10000 "; then
    info "✅ Порт 10000 слушается — всё работает!"
else
    warning "❌ Порт 10000 не слушается. Проверьте вручную."
    echo "Проверьте:"
    echo "  sqlite3 /etc/x-ui/x-ui.db \"SELECT remark, port, listen FROM inbounds WHERE port = 10000;\""
    echo "  journalctl -u x-ui --no-pager -n 20"
fi

# === 7. ВЫВОД ДАННЫХ ===
PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';" 2>/dev/null || echo "2053")
WEB_BASE=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webBasePath';" 2>/dev/null | sed 's|^/||;s|/$||')

echo ""
echo "============================================"
echo "  ПАНЕЛЬ УСТАНОВЛЕНА"
echo "============================================"
echo "  Порт панели: $PANEL_PORT"
echo "  WebBasePath: $WEB_BASE"
echo "  Inbound:     xhttp-cascade (порт 10000)"
echo "  UUID:        $CLIENT_UUID"
echo "============================================"
