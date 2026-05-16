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
systemctl start x-ui
sleep 2

# === 3. ПОЛУЧАЕМ ПАРАМЕТРЫ ИЗ БАЗЫ ===
PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';" 2>/dev/null || echo "2053")
WEB_BASE=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webBasePath';" 2>/dev/null | sed 's|^/||;s|/$||')
info "Порт панели: $PANEL_PORT"
info "WebBasePath: $WEB_BASE"

# === 4. ЛОГИН ===
info "Логинимся в панель..."
LOGIN_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/login" \
    -d "username=admin&password=admin" \
    -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null)

if echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    info "Логин успешен (admin/admin)"
    COOKIE=$(curl -s -c - -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/login" \
        -d "username=admin&password=admin" \
        -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null | grep -oP '3x-ui\s+\K\S+' || true)
else
    error "Не удалось залогиниться: $LOGIN_RESPONSE"
fi

# === 5. СОЗДАНИЕ INBOUND ===
info "Создаём inbound через API..."
STREAM="{\"network\":\"xhttp\",\"security\":\"none\",\"xhttpSettings\":{\"path\":\"$SECRET_PATH\",\"host\":\"$DOMAIN\",\"mode\":\"packet-up\",\"scMaxBufferedPosts\":30,\"scMaxEachPostBytes\":\"1000000-2000000\",\"noSSEHeader\":false,\"xPaddingBytes\":\"100-1000\"},\"sockopt\":{\"tcpFastOpen\":false,\"tcpNoDelay\":true,\"tcpMaxSeg\":1440,\"tcpCongestion\":\"bbr\",\"tcpMptcp\":false,\"tcpKeepAliveIdle\":60,\"tcpKeepAliveInterval\":30,\"tcpUserTimeout\":10000,\"tcpWindowClamp\":600}}"
SETTINGS="{\"clients\":[{\"id\":\"$CLIENT_UUID\",\"flow\":\"\"}],\"decryption\":\"none\"}"
SNIFFING='{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}'

RESPONSE=$(curl -s -b "3x-ui=$COOKIE" -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/xui/inbound/add" \
    -d "up=0&down=0&total=0&remark=xhttp-cascade&enable=true&expiryTime=0&listen=127.0.0.1&port=10000&protocol=vless&settings=$SETTINGS&streamSettings=$STREAM&sniffing=$SNIFFING")

if echo "$RESPONSE" | grep -q '"success":true'; then
    info "Inbound создан успешно"
else
    error "Не удалось создать inbound: $RESPONSE"
fi

# === 6. ПРОВЕРКА ===
systemctl restart x-ui
sleep 3
if ss -tlnp | grep -q ":10000 "; then
    info "Порт 10000 слушается — всё работает!"
else
    warning "Порт 10000 не слушается. Проверьте вручную."
fi
