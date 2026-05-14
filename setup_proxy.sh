#!/usr/bin/env bash
# Скрипт настройки SOCKS5-прокси для ускорения установки
# Запуск: bash setup_proxy.sh --server2 IP_СЕРВЕРА_1 | --server1 IP_СЕРВЕРА_2
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }

[[ $EUID -ne 0 ]] && error "Запустите от root"

setup_server2() {
    local SERVER1_IP=$1
    info "Настройка SOCKS5-прокси на Сервере 2 для Сервера 1 ($SERVER1_IP)"

    ufw allow from "$SERVER1_IP" to any port 1080 proto tcp
    info "Порт 1080 открыт для $SERVER1_IP"

    if grep -q '"tag": "socks-in"' /usr/local/etc/xray/config.json 2>/dev/null; then
        warning "SOCKS5-прокси уже настроен"
    else
        jq '.inbounds += [{"tag":"socks-in","listen":"0.0.0.0","port":1080,"protocol":"socks","settings":{"auth":"noauth","udp":true}}]' \
            /usr/local/etc/xray/config.json > /tmp/config_tmp.json && \
        mv /tmp/config_tmp.json /usr/local/etc/xray/config.json
        info "SOCKS5 inbound добавлен в Xray"
        systemctl restart xray
        info "Xray перезапущен"
    fi

    info "Сервер 2 готов. Теперь на Сервере 1 выполните:"
    info "  bash setup_proxy.sh --server1 $(curl -s ifconfig.me)"
}

setup_server1() {
    local SERVER2_IP=$1
    info "Настройка прокси на Сервере 1 через Сервер 2 ($SERVER2_IP)"

    cat > /etc/apt/apt.conf.d/99-proxy.conf <<EOF
Acquire::http::Proxy "socks5h://$SERVER2_IP:1080";
Acquire::https::Proxy "socks5h://$SERVER2_IP:1080";
EOF
    info "apt настроен на прокси"

    export http_proxy="socks5h://$SERVER2_IP:1080"
    export https_proxy="socks5h://$SERVER2_IP:1080"
    info "Переменные окружения установлены"

    info "Прокси настроен. Запускайте основной скрипт в этой же сессии:"
    info "  bash reverse_proxy.sh --mode full"
    info ""
    info "После установки настройки apt останутся в /etc/apt/apt.conf.d/99-proxy.conf"
    info "Удалить их можно командой: rm /etc/apt/apt.conf.d/99-proxy.conf"
}

case "${1:-}" in
    --server2)
        [[ -z "${2:-}" ]] && error "Укажите IP Сервера 1: bash $0 --server2 IP_СЕРВЕРА_1"
        setup_server2 "$2"
        ;;
    --server1)
        [[ -z "${2:-}" ]] && error "Укажите IP Сервера 2: bash $0 --server1 IP_СЕРВЕРА_2"
        setup_server1 "$2"
        ;;
    *)
        echo "Использование:"
        echo "  На Сервере 2: bash $0 --server2 IP_СЕРВЕРА_1"
        echo "  На Сервере 1: bash $0 --server1 IP_СЕРВЕРА_2"
        exit 1
        ;;
esac
