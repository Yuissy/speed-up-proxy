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

# Экранирование для SQLite
sql_escape() {
    local var="$1"
    echo "${var//\'/\'\'}"
}

# ============================================
# ФУНКЦИИ (идентичны финальному скрипту)
# ============================================

# Модификация дефолтного Xray Template Config (с fallback)
modify_default_template() {
    local server2_ip=$1
    local server2_port=$2
    local server2_uuid=$3
    local secret_path=$4
    
    local db_path="/etc/x-ui/x-ui.db"
    
    # Получаем дефолтный шаблон (может быть пустым)
    local default_template
    default_template=$(sqlite3 "$db_path" "SELECT value FROM settings WHERE key = 'xrayTemplateConfig';" 2>/dev/null || true)
    
    # Если шаблон пуст — генерируем полный JSON с дефолтными секциями
    if [[ -z "$default_template" ]]; then
        warning "Дефолтный шаблон в БД отсутствует. Создаю полный шаблон..."
        default_template='{
  "log": {"loglevel": "warning", "access": "none", "error": "", "dnsLog": false, "maskAddress": ""},
  "api": {"tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"]},
  "inbounds": [],
  "outbounds": [],
  "policy": {
    "levels": {"0": {"statsUserDownlink": true, "statsUserUplink": true}},
    "system": {"statsInboundDownlink": true, "statsInboundUplink": true, "statsOutboundDownlink": false, "statsOutboundUplink": false}
  },
  "routing": {"domainStrategy": "AsIs", "rules": []},
  "stats": {},
  "metrics": {"tag": "metrics_out", "listen": "127.0.0.1:11111"}
}'
    fi
    
    # Наши outbounds
    local new_outbounds
    new_outbounds=$(cat <<OUTEOF
[
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}},
    {
      "tag": "cascade",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$server2_ip",
          "port": $server2_port,
          "users": [{"id": "$server2_uuid", "flow": "", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "fingerprint": "chrome",
        "xhttpSettings": {
          "path": "$secret_path",
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
]
OUTEOF
)

    # Наши правила маршрутизации
    local new_routing
    new_routing=$(cat <<REOF
{
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
      {"type": "field", "domain": ["domain:ifconfig.me","domain:ipinfo.io","domain:2ip.ru","domain:ipify.org","domain:icanhazip.com"], "outboundTag": "blocked"},
      {"type": "field", "protocol": ["bittorrent"], "outboundTag": "blocked"},
      {"type": "field", "domain": ["geosite:category-ads-all","geosite:win-spy"], "outboundTag": "blocked"},
      {"type": "field", "domain": ["ext:geosite_RU.dat:ru-blocked"], "outboundTag": "cascade"},
      {"type": "field", "ip": ["geoip:ru"], "outboundTag": "direct"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "cascade"}
    ]
}
REOF
)
    
    # Заменяем outbounds и routing через jq
    local modified_template
    if ! modified_template=$(jq \
        --argjson outbounds "$new_outbounds" \
        --argjson routing "$new_routing" \
        '.outbounds = $outbounds | .routing = $routing' \
        <<< "$default_template"); then
        error "Не удалось модифицировать шаблон через jq"
    fi
    
    # Сохраняем обратно в БД
    modified_template=$(sql_escape "$modified_template")
    sqlite3 "$db_path" "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayTemplateConfig', '$modified_template');"
    info "Xray Template Config обновлён (модификация дефолтного шаблона)"
}

# Создание inbound на порту 10000 (через SQLite с заголовками)
configure_inbound() {
    local domain=$1
    local secret_path=$2
    local client_uuid=$3
    
    local db_path="/etc/x-ui/x-ui.db"
    if [[ ! -f "$db_path" ]]; then
        error "База данных панели не найдена. Inbound не создан."
    fi
    
    local stream_settings
    stream_settings=$(cat <<STEOF
{
  "network": "xhttp",
  "security": "none",
  "xhttpSettings": {
    "path": "$secret_path",
    "host": "$domain",
    "mode": "packet-up",
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000-2000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000",
    "headers": {
      "Server": "nginx/1.25.0",
      "Content-Type": "text/html; charset=UTF-8",
      "X-Powered-By": "PHP/8.1"
    }
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
    
    local inbound_settings="{\"clients\":[{\"id\":\"$client_uuid\",\"flow\":\"\"}],\"decryption\":\"none\"}"
    local sniffing='{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}'
    local tag="inbound-127.0.0.1:10000"
    
    stream_settings=$(sql_escape "$stream_settings")
    inbound_settings=$(sql_escape "$inbound_settings")
    sniffing=$(sql_escape "$sniffing")
    
    sqlite3 "$db_path" "DELETE FROM inbounds WHERE port = 10000;"
    sqlite3 "$db_path" "INSERT INTO inbounds (user_id, remark, port, protocol, settings, stream_settings, sniffing, listen, enable, tag) VALUES (1, 'xhttp-cascade', 10000, 'vless', '$inbound_settings', '$stream_settings', '$sniffing', '127.0.0.1', 1, '$tag');"
    
    info "Inbound создан успешно"
}

# ============================================
# ШАГ 1: УСТАНОВКА ПАНЕЛИ
# ============================================
info "Устанавливаем панель 3x-ui (последняя версия)..."

INSTALL_OUTPUT=$(echo -e "n\nn\n4\ny" | bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) 2>&1 | tee /dev/stderr)

USERNAME=$(echo "$INSTALL_OUTPUT" | grep -oP 'Username:\s+\K\S+' | tr -d '[:space:]')
PASSWORD=$(echo "$INSTALL_OUTPUT" | grep -oP 'Password:\s+\K\S+' | tr -d '[:space:]')

if [[ -z "$USERNAME" || -z "$PASSWORD" ]]; then
    warning "Не удалось извлечь логин/пароль, используем admin/admin"
else
    info "Логин: $USERNAME"
    info "Пароль: $PASSWORD"
fi

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

# ============================================
# ШАГ 5: МОДИФИЦИРУЕМ ШАБЛОН (МАРШРУТИЗАЦИЯ)
# ============================================
info "Модифицируем дефолтный шаблон..."
modify_default_template "$SERVER2_IP" "$SERVER2_PORT" "$SERVER2_UUID" "$SECRET_PATH"

# ============================================
# ШАГ 6: СОЗДАЁМ INBOUND
# ============================================
info "Создаём inbound..."
configure_inbound "$DOMAIN" "$SECRET_PATH" "$CLIENT_UUID"

# ============================================
# ШАГ 7: ПЕРЕЗАПУСК ДЛЯ ПРИМЕНЕНИЯ ВСЕГО
# ============================================
info "Перезапускаем панель..."
systemctl restart x-ui
sleep 4

# ============================================
# ШАГ 8: ПРОВЕРКИ
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
