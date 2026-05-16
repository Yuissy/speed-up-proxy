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

INSTALL_OUTPUT=$(echo -e "n\nn\n4\ny" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) v2.9.4 2>&1)

USERNAME=$(echo "$INSTALL_OUTPUT" | grep -oP 'Username:\s+\K\S+')
PASSWORD=$(echo "$INSTALL_OUTPUT" | grep -oP 'Password:\s+\K\S+')

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    error "Не удалось извлечь логин/пароль из вывода установки"
fi

info "Логин: $USERNAME"
info "Пароль: $PASSWORD"

# === 2. ПОЛУЧАЕМ ПОРТ И WEB_BASE ===
PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';")
WEB_BASE=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webBasePath';" | sed 's|^/||;s|/$||')
info "Порт: $PANEL_PORT, Путь: $WEB_BASE"

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

grep -q '3x-ui' /tmp/xui-cookie.txt || error "Не удалось залогиниться"
info "Сессия получена"

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

echo "$RESPONSE" | grep -q '"success":true' || error "Ошибка создания inbound: $RESPONSE"
info "Inbound создан"

# === 6. ПРОВЕРКА ===
sleep 2
ss -tlnp | grep -q ":10000 " && info "✅ Порт 10000 слушается!" || warning "❌ Порт 10000 не слушается"

echo ""
echo "============================================"
echo "  ПАНЕЛЬ УСТАНОВЛЕНА"
echo "============================================"
echo "  Порт панели: $PANEL_PORT"
echo "  WebBasePath: $WEB_BASE"
echo "  Логин:       $USERNAME"
echo "  Пароль:      $PASSWORD"
echo "  Inbound:     xhttp-cascade (порт 10000)"
echo "  UUID:        $CLIENT_UUID"
echo "============================================"
