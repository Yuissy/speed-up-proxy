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
# ТЕСТОВЫЕ ПАРАМЕТРЫ (замени на свои от Сервера 2)
# ============================================
DOMAIN="visualk-play.online"
SECRET_PATH="/updates/templates/assets/v3/conf"
CLIENT_UUID="fe4ab9ef-c336-4980-91b2-342102dc45ba"
WEB_BASE_PATH="MyTestPanel123"

# Параметры Сервера 2 (замени на реальные!)
SERVER2_IP="144.31.66.45"
SERVER2_PORT=42376
SERVER2_UUID="80a8e7de-45a2-4041-b884-f646331fdb07"

# Экранирование для SQLite
sql_escape() {
    local var="$1"
    echo "${var//\'/\'\'}"
}

# ============================================
# ШАГ 1: УСТАНОВКА ПАНЕЛИ
# ============================================
info "Устанавливаем панель 3x-ui v2.9.4..."

echo -e "n\nn\n4\ny" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) v2.9.4 2>&1 | tee /dev/stderr | grep -E "(Username:|Password:|Port:|Web Base Path:|installation finished|Error)" || true

info "Ждём полной инициализации панели..."
sleep 5

# ============================================
# ШАГ 2: НАСТРОЙКА ЧЕРЕЗ CLI
# ============================================
info "Настраиваем логин/пароль через CLI..."
/usr/local/x-ui/x-ui setting -username "admin" -password "admin" -resetTwoFactor true
info "Логин/пароль установлены: admin / admin"

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
# ШАГ 4: ПЕРЕЗАПУСК ПАНЕЛИ ДЛЯ ПРИМЕНЕНИЯ НАСТРОЕК
# ============================================
info "Перезапускаем панель..."
systemctl restart x-ui
sleep 4

# Проверяем, что панель слушает localhost
info "Проверяем интерфейс панели..."
ss -tlnp | grep "$PANEL_PORT"

# ============================================
# ШАГ 5: СОЗДАЁМ INBOUND ЧЕРЕЗ SQLITE
# ============================================
info "Создаём inbound через БД..."

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
SNIFFING='{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}'

STREAM_SETTINGS=$(sql_escape "$STREAM_SETTINGS")
INBOUND_SETTINGS=$(sql_escape "$INBOUND_SETTINGS")
SNIFFING=$(sql_escape "$SNIFFING")

sqlite3 /etc/x-ui/x-ui.db "DELETE FROM inbounds WHERE port = 10000;"
sqlite3 /etc/x-ui/x-ui.db "INSERT INTO inbounds (remark, port, protocol, settings, stream_settings, sniffing, listen, enable) VALUES ('xhttp-cascade', 10000, 'vless', '$INBOUND_SETTINGS', '$STREAM_SETTINGS', '$SNIFFING', '127.0.0.1', 1);"

info "Inbound вставлен в БД"

# ============================================
# ШАГ 5.5: XRAY TEMPLATE CONFIG (МАРШРУТИЗАЦИЯ)
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
        },
        "sockopt": {
          "tcpFastOpen": false, "tcpNoDelay": true, "tcpMaxSeg": 1440,
          "tcpCongestion": "bbr", "tcpMptcp": false,
          "tcpKeepAliveIdle": 60, "tcpKeepAliveInterval": 30,
          "tcpUserTimeout": 10000, "tcpWindowClamp": 600
        }
      }
    },
    {"tag": "blocked", "protocol": "blackhole", "settings": {}}
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "domain": ["geosite:category-ads","geosite:win-spy"], "outboundTag": "blocked"},
      {"type": "field", "domain": ["domain:ifconfig.me","domain:ipinfo.io","domain:2ip.ru","domain:ipify.org","domain:icanhazip.com"], "outboundTag": "blocked"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
      {"type": "field", "ip": ["geoip:direct"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:category-ru","geosite:whitelist"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:apple","geosite:microsoft","geosite:steam","geosite:epic-games","geosite:riot","geosite:escapefromtarkov","geosite:faceit","geosite:pinterest","geosite:twitch"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:youtube","geosite:telegram","geosite:github","geosite:google-play"], "outboundTag": "cascade"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "cascade"}
    ]
  }
}
XEOF
)

XRAY_TEMPLATE=$(sql_escape "$XRAY_TEMPLATE")
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value = '$XRAY_TEMPLATE' WHERE key = 'xrayTemplateConfig';"
info "Маршрутизация записана"

# ============================================
# ШАГ 6: ПЕРЕЗАПУСК ДЛЯ ПРИМЕНЕНИЯ ВСЕХ ИЗМЕНЕНИЙ
# ============================================
info "Перезапускаем панель для применения inbound и маршрутизации..."
systemctl restart x-ui
sleep 4

# ============================================
# ШАГ 7: ПРОВЕРКА ПОРТА 10000
# ============================================
info "Проверяем порт 10000..."
if ss -tlnp | grep -q ":10000 "; then
    info "✅ Порт 10000 слушается!"
else
    warning "❌ Порт 10000 не слушается"
fi

# ============================================
# ШАГ 8: ПРОВЕРКА ЛОГИНА В ПАНЕЛЬ
# ============================================
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
# ШАГ 9: ПРОВЕРКА INBOUND ЧЕРЕЗ API
# ============================================
info "Проверяем inbound через API..."

# Получаем куку
curl -s -c /tmp/xui-cookie.txt -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE_PATH}/login" \
    -d '{"Username":"admin","Password":"admin"}' \
    -H "Content-Type: application/json" > /dev/null

# Запрашиваем список inbound'ов
INBOUND_LIST=$(curl -s -b /tmp/xui-cookie.txt "http://127.0.0.1:$PANEL_PORT/${WEB_BASE_PATH}/panel/api/inbounds/list")
echo "$INBOUND_LIST" | python3 -m json.tool 2>/dev/null || echo "$INBOUND_LIST"

# Проверяем, что наш inbound есть
if echo "$INBOUND_LIST" | grep -q "xhttp-cascade"; then
    info "✅ Inbound 'xhttp-cascade' найден через API"
else
    warning "❌ Inbound не найден через API"
fi

# ============================================
# ШАГ 10: ПРОВЕРКА XRAYTEMPLATECONFIG
# ============================================
info "Проверяем xrayTemplateConfig в БД..."
TEMPLATE_CHECK=$(sqlite3 /etc/x-ui/x-ui.db "SELECT substr(value, 1, 100) FROM settings WHERE key = 'xrayTemplateConfig';")
if [[ -n "$TEMPLATE_CHECK" ]]; then
    info "✅ xrayTemplateConfig записан (первые 100 символов):"
    echo "$TEMPLATE_CHECK"
else
    warning "❌ xrayTemplateConfig пуст!"
fi

# ============================================
# ФИНАЛЬНЫЙ ВЫВОД
# ============================================
echo ""
echo "============================================"
echo "  ТЕСТОВАЯ УСТАНОВКА ЗАВЕРШЕНА"
echo "============================================"
echo "  Порт панели: $PANEL_PORT"
echo "  WebBasePath: $WEB_BASE_PATH"
echo "  Логин:       admin"
echo "  Пароль:      admin"
echo "  Inbound:     xhttp-cascade (порт 10000)"
echo "  UUID:        $CLIENT_UUID"
echo "  Сервер 2:    $SERVER2_IP:$SERVER2_PORT"
echo "============================================"
echo ""
echo "  ДОСТУП К ПАНЕЛИ:"
echo "  ssh -L 2222:127.0.0.1:$PANEL_PORT root@<IP_СЕРВЕРА>"
echo "  Затем открыть: http://127.0.0.1:2222/$WEB_BASE_PATH"
echo ""
echo "  ПРОВЕРКА КАСКАДА:"
echo "  Настрой клиент v2rayN/Nekobox:"
echo "    Адрес: $DOMAIN"
echo "    Порт: 443"
echo "    Путь: $SECRET_PATH"
echo "    UUID: $CLIENT_UUID"
echo "    Тип: VLESS + XHTTP"
echo "============================================"
