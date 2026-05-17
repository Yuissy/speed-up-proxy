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

# ============================================
# ПАРАМЕТРЫ (замени на свои от Сервера 2)
# ============================================
DOMAIN="visualk-play.online"
SECRET_PATH="/updates/templates/assets/v3/conf"
CLIENT_UUID="fe4ab9ef-c336-4980-91b2-342102dc45ba"
WEB_BASE_PATH="MyTestPanel123"

SERVER2_IP="144.31.66.45"
SERVER2_PORT=42376
SERVER2_UUID="80a8e7de-45a2-4041-b884-f646331fdb07"

# Geo-файлы RoscomVPN
GEOIP_URL="https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat"
GEOSITE_URL="https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat"

# Экранирование для SQLite
sql_escape() {
    local var="$1"
    echo "${var//\'/\'\'}"
}

# ============================================
# ШАГ 1: УСТАНОВКА ПАНЕЛИ (ПОСЛЕДНЯЯ ВЕРСИЯ)
# ============================================
info "Устанавливаем панель 3x-ui (последняя версия)..."

INSTALL_OUTPUT=$(echo -e "n\nn\n4\ny" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) 2>&1 | tee /dev/stderr)

USERNAME=$(echo "$INSTALL_OUTPUT" | grep -oP 'Username:\s+\K\S+' | tr -d '[:space:]')
PASSWORD=$(echo "$INSTALL_OUTPUT" | grep -oP 'Password:\s+\K\S+' | tr -d '[:space:]')

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    error "Не удалось извлечь логин/пароль из вывода установки"
fi

info "Логин: $USERNAME"
info "Пароль: $PASSWORD"

info "Ждём инициализации панели..."
sleep 5

# ============================================
# ШАГ 2: НАСТРОЙКА ЧЕРЕЗ CLI
# ============================================
info "Меняем логин/пароль на admin/admin..."
/usr/local/x-ui/x-ui setting -username "admin" -password "admin" -resetTwoFactor true
info "Логин/пароль: admin / admin"

info "Привязываем панель к localhost..."
/usr/local/x-ui/x-ui setting -listenIP "127.0.0.1"

info "Меняем WebBasePath..."
/usr/local/x-ui/x-ui setting -webBasePath "/${WEB_BASE_PATH}/"

# ============================================
# ШАГ 3: ПОЛУЧАЕМ ПОРТ
# ============================================
PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key = 'webPort';")
info "Порт панели: $PANEL_PORT"

# ============================================
# ШАГ 4: ПЕРЕЗАПУСК ДЛЯ ПРИМЕНЕНИЯ CLI-НАСТРОЕК
# ============================================
info "Перезапускаем панель..."
systemctl restart x-ui
sleep 4

info "Проверяем интерфейс панели..."
ss -tlnp | grep "$PANEL_PORT"

# ============================================
# ШАГ 5: СКАЧИВАЕМ GEO-ФАЙЛЫ
# ============================================
info "Скачиваем geo-файлы RoscomVPN..."

mkdir -p /usr/local/share/xray /usr/local/x-ui/bin

curl -L --max-time 60 -o /usr/local/share/xray/geoip.dat "$GEOIP_URL"
curl -L --max-time 60 -o /usr/local/share/xray/geosite.dat "$GEOSITE_URL"

# Копируем в папку панели
cp /usr/local/share/xray/geoip.dat /usr/local/x-ui/bin/geoip.dat
cp /usr/local/share/xray/geosite.dat /usr/local/x-ui/bin/geosite.dat

info "Geo-файлы установлены"

# ============================================
# ШАГ 6: СОЗДАЁМ INBOUND ЧЕРЕЗ SQLITE
# ============================================
info "Создаём inbound XHTTP..."

STREAM_SETTINGS=$(cat <<STEOF
{
  "network": "xhttp",
  "security": "none",
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
}
STEOF
)

INBOUND_SETTINGS="{\"clients\":[{\"id\":\"$CLIENT_UUID\",\"flow\":\"\"}],\"decryption\":\"none\"}"
# Только http и tls, без quic и fakedns
SNIFFING='{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}'
TAG="inbound-127.0.0.1:10000"

STREAM_SETTINGS=$(sql_escape "$STREAM_SETTINGS")
INBOUND_SETTINGS=$(sql_escape "$INBOUND_SETTINGS")
SNIFFING=$(sql_escape "$SNIFFING")

# Удаляем старый inbound на порту 10000
sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds WHERE port = 10000;"

# Вставляем новый (с tag и user_id)
sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (user_id, remark, port, protocol, settings, stream_settings, sniffing, listen, enable, tag) VALUES (1, 'xhttp-cascade', 10000, 'vless', '$INBOUND_SETTINGS', '$STREAM_SETTINGS', '$SNIFFING', '127.0.0.1', 1, '$TAG');"

info "Inbound создан"

# ============================================
# ШАГ 7: XRAY TEMPLATE CONFIG (МАРШРУТИЗАЦИЯ)
# ============================================
info "Записываем маршрутизацию..."

XRAY_TEMPLATE=$(cat <<XEOF
{
  "outbounds": [
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {
      "tag": "cascade",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$SERVER2_IP",
          "port": $SERVER2_PORT,
          "users": [{"id": "$SERVER2_UUID", "flow": "", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "fingerprint": "chrome",
        "xhttpSettings": {
          "path": "$SECRET_PATH",
          "host": "",
          "mode": "packet-up",
          "scMaxBufferedPosts": 30,
          "scMaxEachPostBytes": "1000000-2000000",
          "noSSEHeader": false,
          "xPaddingBytes": "100-1000"
        }
      }
    },
    {"tag": "blocked", "protocol": "blackhole", "settings": {}}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "domain": ["geosite:CATEGORY-ADS","geosite:WIN-SPY","geosite:TORRENT"], "outboundTag": "blocked"},
      {"type": "field", "domain": ["domain:ifconfig.me","domain:ipinfo.io","domain:2ip.ru","domain:ipify.org","domain:icanhazip.com"], "outboundTag": "blocked"},
      {"type": "field", "ip": ["geoip:PRIVATE"], "outboundTag": "direct"},
      {"type": "field", "ip": ["geoip:DIRECT"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:CATEGORY-RU","geosite:APPLE","geosite:STEAM","geosite:RIOT","geosite:ESCAPEFROMTARKOV","geosite:FACEIT","geosite:TWITCH"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:YOUTUBE","geosite:TELEGRAM","geosite:GITHUB","geosite:GOOGLE-PLAY"], "outboundTag": "cascade"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "cascade"}
    ]
  }
}
XEOF
)

XRAY_TEMPLATE=$(sql_escape "$XRAY_TEMPLATE")
sqlite3 /etc/x-ui/x-ui.db "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayTemplateConfig', '$XRAY_TEMPLATE');"
info "Маршрутизация записана"

# ============================================
# ШАГ 8: ПЕРЕЗАПУСК ДЛЯ ПРИМЕНЕНИЯ ВСЕГО
# ============================================
info "Перезапускаем панель..."
systemctl restart x-ui
sleep 4

# ============================================
# ШАГ 9: ПРОВЕРКИ
# ============================================
info "Проверяем порт 10000..."
if ss -tlnp | grep -q ":10000 "; then
    info "✅ Порт 10000 слушается!"
else
    warning "❌ Порт 10000 не слушается"
fi

info "Проверяем Xray..."
journalctl -u x-ui -n 5 --no-pager | grep -E "(started|ERROR|Warning)" || true

info "Проверяем логин в панель..."
LOGIN_RESPONSE=$(curl -s -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE_PATH}/login" \
    -d '{"Username":"admin","Password":"admin"}' \
    -H "Content-Type: application/json")

if echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
    info "✅ Логин успешен"
else
    warning "❌ Логин не удался: $LOGIN_RESPONSE"
fi

# ============================================
# ФИНАЛЬНЫЙ ВЫВОД
# ============================================
echo ""
echo "============================================"
echo "  ТЕСТОВАЯ УСТАНОВКА ЗАВЕРШЕНА"
echo "============================================"
echo "  Панель:      http://127.0.0.1:$PANEL_PORT/$WEB_BASE_PATH"
echo "  Логин:       admin"
echo "  Пароль:      admin"
echo "  Inbound:     xhttp-cascade (порт 10000)"
echo "  UUID:        $CLIENT_UUID"
echo "  Домен:       $DOMAIN"
echo "  Сервер 2:    $SERVER2_IP:$SERVER2_PORT"
echo "============================================"
echo ""
echo "  ДОСТУП К ПАНЕЛИ:"
echo "  ssh -L 2222:127.0.0.1:$PANEL_PORT root@<IP>"
echo "  http://127.0.0.1:2222/$WEB_BASE_PATH"
echo ""
echo "  КЛИЕНТ v2rayN/Nekobox:"
echo "    Адрес: $DOMAIN"
echo "    Порт: 443"
echo "    Путь: $SECRET_PATH"
echo "    UUID: $CLIENT_UUID"
echo "    Тип: VLESS + XHTTP (packet-up)"
echo "============================================"
