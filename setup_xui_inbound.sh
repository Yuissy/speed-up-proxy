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

info "Устанавливаем панель 3x-ui v2.9.4..."
INSTALL_LOG="/tmp/x-ui-install.log"
echo -e "n\nn\n4\ny" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) v2.9.4 | tee "$INSTALL_LOG"

ADMIN_USER=$(grep -oP 'Username:\s+\K\S+' "$INSTALL_LOG" | head -1)
ADMIN_PASS=$(grep -oP 'Password:\s+\K\S+' "$INSTALL_LOG" | head -1)
PANEL_PORT=$(grep -oP 'Port:\s+\K\d+' "$INSTALL_LOG" | head -1)
WEB_BASE=$(grep -oP 'WebBasePath:\s+\K\S+' "$INSTALL_LOG" | head -1)

info "Порт панели: $PANEL_PORT"
info "WebBasePath: $WEB_BASE"
info "Логин: $ADMIN_USER"

sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';"
systemctl restart x-ui
sleep 2

info "Логинимся в панель..."
LOGIN_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/login" \
    -d "username=$ADMIN_USER&password=$ADMIN_PASS" \
    -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null)

if echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    info "Логин успешен"
    COOKIE=$(curl -s -c - -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/login" \
        -d "username=$ADMIN_USER&password=$ADMIN_PASS" \
        -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null | grep -oP '3x-ui\s+\K\S+' || true)
else
    warning "Ответ логина: $LOGIN_RESPONSE"
    info "Пробуем admin/admin..."
    LOGIN_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/login" \
        -d "username=admin&password=admin" \
        -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null)
    if echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
        info "Залогинились с admin/admin, меняем пароль..."
        COOKIE=$(curl -s -c - -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/login" \
            -d "username=admin&password=admin" \
            -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null | grep -oP '3x-ui\s+\K\S+' || true)
        ADMIN_USER="admin"
        ADMIN_PASS=$(openssl rand -base64 12)
        curl -s -b "3x-ui=$COOKIE" -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/xui/setting/update" \
            -d "username=admin&password=$ADMIN_PASS&webPort=$PANEL_PORT&webBasePath=$WEB_BASE" \
            -H "Content-Type: application/x-www-form-urlencoded" 2>/dev/null
    else
        error "Не удалось залогиниться: $LOGIN_RESPONSE"
    fi
fi

info "Создаём inbound через API..."
STREAM_SETTINGS="{\"network\":\"xhttp\",\"security\":\"none\",\"xhttpSettings\":{\"path\":\"$SECRET_PATH\",\"host\":\"$DOMAIN\",\"mode\":\"packet-up\",\"scMaxBufferedPosts\":30,\"scMaxEachPostBytes\":\"1000000-2000000\",\"noSSEHeader\":false,\"xPaddingBytes\":\"100-1000\"},\"sockopt\":{\"tcpFastOpen\":false,\"tcpNoDelay\":true,\"tcpMaxSeg\":1440,\"tcpCongestion\":\"bbr\",\"tcpMptcp\":false,\"tcpKeepAliveIdle\":60,\"tcpKeepAliveInterval\":30,\"tcpUserTimeout\":10000,\"tcpWindowClamp\":600}}"
SETTINGS="{\"clients\":[{\"id\":\"$CLIENT_UUID\",\"flow\":\"\"}],\"decryption\":\"none\"}"
SNIFFING='{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}'

RESPONSE=$(curl -s -b "3x-ui=$COOKIE" -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/xui/inbound/add" \
    -H "Content-Type: application/json" \
    -d "{\"up\":0,\"down\":0,\"total\":0,\"remark\":\"xhttp-cascade\",\"enable\":true,\"expiryTime\":0,\"listen\":\"127.0.0.1\",\"port\":10000,\"protocol\":\"vless\",\"settings\":\"$SETTINGS\",\"streamSettings\":\"$STREAM_SETTINGS\",\"sniffing\":\"$SNIFFING\"}" 2>/dev/null)

if echo "$RESPONSE" | grep -q '"success":true'; then
    info "Inbound создан успешно"
else
    error "Не удалось создать inbound: $RESPONSE"
fi

systemctl restart x-ui
sleep 3
if ss -tlnp | grep -q ":10000 "; then
    info "Порт 10000 слушается — всё работает!"
else
    warning "Порт 10000 не слушается. Проверьте вручную."
fi

rm -f "$INSTALL_LOG"
