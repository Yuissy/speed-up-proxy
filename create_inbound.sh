#!/usr/bin/env bash
# Запуск: bash create_inbound.sh PANEL_PORT WEB_BASE DOMAIN SECRET_PATH CLIENT_UUID

PANEL_PORT="$1"
WEB_BASE="$2"
DOMAIN="$3"
SECRET_PATH="$4"
CLIENT_UUID="$5"

# Парсим логин/пароль из лога установки
USERNAME=$(grep -oP 'Username:\s+\K\S+' /tmp/install.log 2>/dev/null | tail -1 | tr -d '[:space:]')
PASSWORD=$(grep -oP 'Password:\s+\K\S+' /tmp/install.log 2>/dev/null | tail -1 | tr -d '[:space:]')

# Логин
curl -s -c /tmp/xui-cookie.txt --max-time 10 -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/login" \
    -d "{\"Username\":\"$USERNAME\",\"Password\":\"$PASSWORD\"}" \
    -H "Content-Type: application/json" > /dev/null

# Создать inbound
curl -s -b /tmp/xui-cookie.txt -X POST "http://127.0.0.1:$PANEL_PORT/${WEB_BASE}/panel/api/inbounds/add" \
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
}" | grep -q '"success":true' && echo "✅ Inbound создан" || echo "❌ Ошибка создания inbound"
