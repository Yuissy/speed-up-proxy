#!/usr/bin/env bash
set -euo pipefail

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[✓]${NC} $*"; }
error() { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Запустите от root"

DOMAIN="visualk-play.online"
SECRET_PATH="/updates/templates/assets/v3/conf"
CLIENT_UUID="fe4ab9ef-c336-4980-91b2-342102dc45ba"

# === 1. УСТАНОВКА ПАНЕЛИ ===
info "Устанавливаем панель 3x-ui v2.9.4..."
echo -e "n\nn\n4\ny" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) v2.9.4 2>&1 | tee /tmp/install.log

# === 2. ПРИВЯЗЫВАЕМ К LOCALHOST ===
info "Настраиваем панель..."
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';"
systemctl start x-ui
sleep 3

# === 3. ПОЛУЧАЕМ ПАРАМЕТРЫ ===
PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';")
WEB_BASE=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webBasePath';" | sed 's|^/||;s|/$||')
USERNAME=$(grep -oP 'Username:\s+\K\S+' /tmp/install.log | tail -1 | tr -d '[:space:]')
PASSWORD=$(grep -oP 'Password:\s+\K\S+' /tmp/install.log | tail -1 | tr -d '[:space:]')

info "Порт: $PANEL_PORT, Путь: $WEB_BASE"
info "Логин: $USERNAME"

# === 4. СОЗДАЁМ INBOUND ЧЕРЕЗ ВНЕШНИЙ СКРИПТ ===
info "Создаём inbound через API..."
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/speed-up-proxy/main/create_inbound.sh) \
    "$PANEL_PORT" "$WEB_BASE" "$DOMAIN" "$SECRET_PATH" "$CLIENT_UUID" "$USERNAME" "$PASSWORD" || error "Не удалось создать inbound"

# === 5. ПРОВЕРКА ===
sleep 2
ss -tlnp | grep -q ":10000 " && info "✅ Порт 10000 слушается!" || error "❌ Порт 10000 не слушается"

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
