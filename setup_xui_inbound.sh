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

# === 2. ЖДЁМ ИНИЦИАЛИЗАЦИЮ ===
info "Ждём инициализацию панели..."
sleep 5

# === 3. ЗАДАЁМ ЛОГИН/ПАРОЛЬ И ПРИВЯЗЫВАЕМ К LOCALHOST ===
info "Настраиваем панель через CLI..."
/usr/local/x-ui/x-ui setting -username "admin" -password "admin" -resetTwoFactor true
/usr/local/x-ui/x-ui setting -listenIP "127.0.0.1"

info "Панель настроена: admin/admin, слушает 127.0.0.1"

# === 4. ПОЛУЧАЕМ ПОРТ И WEB_BASE ===
PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';")
WEB_BASE=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webBasePath';")
WEB_BASE="${WEB_BASE#/}"
WEB_BASE="${WEB_BASE%/}"
info "Порт: $PANEL_PORT, Путь: $WEB_BASE"

# === 5. ДОБАВЛЯЕМ INBOUND В БД ===
info "Добавляем inbound в БД..."

STREAM=$(cat <<STEOF
{"network":"xhttp","security":"none","xhttpSettings":{"path":"$SECRET_PATH","host":"$DOMAIN","mode":"packet-up","scMaxBufferedPosts":30,"scMaxEachPostBytes":"1000000-2000000","noSSEHeader":false,"xPaddingBytes":"100-1000"},"sockopt":{"tcpFastOpen":false,"tcpNoDelay":true,"tcpMaxSeg":1440,"tcpCongestion":"bbr","tcpMptcp":false,"tcpKeepAliveIdle":60,"tcpKeepAliveInterval":30,"tcpUserTimeout":10000,"tcpWindowClamp":600}}
STEOF
)

SETTINGS="{\"clients\":[{\"id\":\"$CLIENT_UUID\",\"flow\":\"\"}],\"decryption\":\"none\"}"
SNIFFING='{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}'

# Экранируем кавычки для SQLite
STREAM_ESC="${STREAM//\'/\'\'}"
SETTINGS_ESC="${SETTINGS//\'/\'\'}"
SNIFFING_ESC="${SNIFFING//\'/\'\'}"

sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds WHERE port = 10000;"
sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (remark, port, protocol, settings, stream_settings, sniffing, listen, enable) VALUES ('xhttp-cascade', 10000, 'vless', '$SETTINGS_ESC', '$STREAM_ESC', '$SNIFFING_ESC', '127.0.0.1', 1);"

info "Inbound добавлен в БД"

# === 6. ПЕРЕЗАПУСКАЕМ ПАНЕЛЬ ===
info "Перезапускаем панель..."
systemctl restart x-ui
sleep 3

# === 7. ПРОВЕРКА ===
if ss -tlnp | grep -q ":10000 "; then
    info "✅ Порт 10000 слушается!"
else
    warning "❌ Порт 10000 не слушается"
fi

echo ""
echo "============================================"
echo "  ПАНЕЛЬ УСТАНОВЛЕНА"
echo "============================================"
echo "  Порт панели: $PANEL_PORT"
echo "  WebBasePath: $WEB_BASE"
echo "  Логин:       admin"
echo "  Пароль:      admin"
echo "  Inbound:     xhttp-cascade (порт 10000)"
echo "  UUID:        $CLIENT_UUID"
echo "============================================"
