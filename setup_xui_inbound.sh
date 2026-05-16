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

# === 2. ПОЛУЧАЕМ ДАННЫЕ ИЗ БД ===
info "Получаем параметры панели из БД..."
PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';")
WEB_BASE=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webBasePath';" | sed 's|^/||;s|/$||')
USERNAME=$(sqlite3 /etc/x-ui/x-ui.db "SELECT username FROM users WHERE id = 1;")
PASSWORD=$(sqlite3 /etc/x-ui/x-ui.db "SELECT password FROM users WHERE id = 1;")

info "Порт: $PANEL_PORT, Путь: $WEB_BASE"
info "Логин: $USERNAME"

# === 3. ПРИВЯЗЫВАЕМ К LOCALHOST ===
info "Привязываем панель к localhost..."
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';"
systemctl start x-ui
sleep 3

# === 4. ЛОГИН ===
info "Логинимся в панель..."
curl -s -c /tmp/xui-cookie.txt -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/login" \
    -d "{\"Username\":\"$USERNAME\",\"Password\":\"$PASSWORD\"}" \
    -H "Content-Type: application/json" > /dev/null

if grep -q '3x-ui' /tmp/xui-cookie.txt; then
    info "Сессия получена"
else
    error "Не удалось залогиниться"
fi

# === 5. СОЗДАЁМ INBOUND ===
info "Создаём inbound..."

RESPONSE=$(curl -s -b /tmp/xui-cookie.txt -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/panel/api/inbounds/add" \
    -H "Content-Type: application/json" \
    -d "{
  \"remark\": \"xhttp-cascade\",
  \"enable\": true,
  \"port\": 10000,
  \"protocol\": \"vless\",
  \"listen\": \"127.0.0.1\",
  \"settings\": \"{\\\"clients\\\":[{\\\"id\\\":\\\"$CLIENT_UUID\\\",\\\"flow\\\":\\\"\\\"}],\\\"decryption\\\":\\\"none\\\"}\",
  \"streamSettings\": \"{\\\"network\\\":\\\"xhttp\\\",\\\"security\\\":\\\"none\\\",\\\"xhttpSettings\\\":{\\\"path\\\":\\\"$SECRET_PATH\\\",\\\"host\\\":\\\"$DOMAIN\\\",\\\"mode\\\":\\\"packet-up\\\",\\\"scMaxBufferedPosts\\\":30,\\\"scMaxEachPostBytes\\\":\\\"1000000-2000000\\\",\\\"noSSEHeader\\\":false,\\\"xPaddingBytes\\\":\\\"100-1000\\\"},\\\"sockopt\\\":{\\\"tcpFastOpen\\\":false,\\\"tcpNoDelay\\\":true,\\\"tcpMaxSeg\\\":1440,\\\"tcpCongestion\\\":\\\"bbr\\\",\\\"tcpMptcp\\\":false,\\\"tcpKeepAliveIdle\\\":60,\\\"tcpKeepAliveInterval\\\":30,\\\"tcpUserTimeout\\\":10000,\\\"tcpWindowClamp\\\":600}}\",
  \"sniffing\": \"{\\\"enabled\\\":true,\\\"destOverride\\\":[\\\"http\\\",\\\"tls\\\"],\\\"routeOnly\\\":true}\"
}")

if echo "$RESPONSE" | grep -q '"success":true'; then
    info "Inbound создан"
else
    error "Ошибка создания inbound: $RESPONSE"
fi

# === 6. ПРОВЕРКА ===
sleep 2
if ss -tlnp | grep -q ":10000 "; then
    info "✅ Порт 10000 слушается — всё работает!"
else
    warning "❌ Порт 10000 не слушается"
fi

# === 7. ВЫВОД ===
echo ""
echo "============================================"
echo "  ПАНЕЛЬ УСТАНОВЛЕНА"
echo "============================================"
echo "  Порт панели: $PANEL_PORT"
echo "  WebBasePath: $WEB_BASE"
echo "  Inbound:     xhttp-cascade (порт 10000)"
echo "  UUID:        $CLIENT_UUID"
echo "============================================"
