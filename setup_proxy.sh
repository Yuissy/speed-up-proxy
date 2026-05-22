#!/usr/bin/env bash
# Скрипт настройки/удаления SOCKS5-прокси и теста скорости
# Запуск: bash setup_proxy.sh [--server1 IP | --server2 IP | --cleanup-server1 | --cleanup-server2 | --speedtest]
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}=== $* ===${NC}"; }

[[ $EUID -ne 0 ]] && error "Запустите от root"

# ---------- Сервер 2: настройка прокси ----------
setup_server2() {
    local SERVER1_IP="$1"
    section "Настройка SOCKS5-прокси на Сервере 2 для Сервера 1 ($SERVER1_IP)"

    # Установка jq при необходимости
    if ! command -v jq &>/dev/null; then
        apt update -qq && apt install -y jq
        info "jq установлен"
    fi

    # Открываем порт только для Сервера 1
    ufw allow from "$SERVER1_IP" to any port 1080 proto tcp
    info "Порт 1080 открыт для $SERVER1_IP"

    local CONFIG="/usr/local/etc/xray/config.json"
    if grep -q '"tag": "socks-in"' "$CONFIG" 2>/dev/null; then
        warning "SOCKS5-прокси уже настроен"
    else
        if jq '.inbounds += [{"tag":"socks-in","listen":"0.0.0.0","port":1080,"protocol":"socks","settings":{"auth":"noauth","udp":true}}]' \
            "$CONFIG" > /tmp/config_tmp.json; then
            mv /tmp/config_tmp.json "$CONFIG"
            info "SOCKS5 inbound добавлен в Xray"
            systemctl restart xray
            info "Xray перезапущен"
        else
            error "Не удалось обновить конфиг Xray. Проверьте JSON-валидность $CONFIG"
        fi
    fi

    local public_ip
    public_ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    echo ""
    info "Сервер 2 готов. Теперь на Сервере 1 выполните:"
    info "  bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/setup_proxy.sh) --server1 $public_ip"
    echo ""
    warning "Если IP Сервера 1 изменится, доступ к прокси пропадёт."
    warning "Обновите правило UFW: ufw delete allow from $SERVER1_IP to any port 1080 proto tcp && ufw allow from НОВЫЙ_IP to any port 1080 proto tcp"
}

# ---------- Сервер 1: настройка прокси ----------
setup_server1() {
    local SERVER2_IP="$1"
    section "Настройка прокси на Сервере 1 через Сервер 2 ($SERVER2_IP)"

    cat > /etc/apt/apt.conf.d/99-proxy.conf <<EOF
Acquire::http::Proxy "socks5h://$SERVER2_IP:1080";
Acquire::https::Proxy "socks5h://$SERVER2_IP:1080";
EOF
    info "apt настроен на прокси"

    export http_proxy="socks5h://$SERVER2_IP:1080"
    export https_proxy="socks5h://$SERVER2_IP:1080"
    info "Переменные окружения установлены"

    echo ""
    info "Прокси настроен. Запускайте основной скрипт в этой же сессии:"
    info "  bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/reverse_proxy_v2.sh) --mode full"
    info ""
    info "После установки настройки apt останутся в /etc/apt/apt.conf.d/99-proxy.conf"
    info "Удалить их можно командой: rm /etc/apt/apt.conf.d/99-proxy.conf"
}

# ---------- Сервер 2: удаление прокси ----------
cleanup_server2() {
    section "Удаление SOCKS5-прокси на Сервере 2"

    local CONFIG="/usr/local/etc/xray/config.json"
    # Удаляем правило UFW для порта 1080
    local rule_nums=$(ufw status numbered | grep '1080/tcp' | awk '{print $1}' | tr -d '[]' | sort -rn)
    if [[ -n "$rule_nums" ]]; then
        for num in $rule_nums; do
            ufw --force delete "$num"
            info "Удалено правило UFW №$num (порт 1080)"
        done
    else
        warning "Правила UFW для порта 1080 не найдены"
    fi

    # Удаляем inbound socks-in из конфига Xray
    if grep -q '"tag": "socks-in"' "$CONFIG" 2>/dev/null; then
        if command -v jq &>/dev/null; then
            jq 'del(.inbounds[] | select(.tag == "socks-in"))' "$CONFIG" > /tmp/config_tmp.json && \
            mv /tmp/config_tmp.json "$CONFIG"
            info "Inbound 'socks-in' удалён из конфига Xray"
            systemctl restart xray
            info "Xray перезапущен"
        else
            warning "jq не установлен, не могу удалить inbound из JSON. Установите jq или удалите вручную."
        fi
    else
        warning "Inbound 'socks-in' не найден в конфиге Xray"
    fi

    info "Прокси на Сервере 2 полностью удалён"
}

# ---------- Сервер 1: удаление прокси ----------
cleanup_server1() {
    section "Удаление прокси на Сервере 1"

    if [[ -f /etc/apt/apt.conf.d/99-proxy.conf ]]; then
        rm -f /etc/apt/apt.conf.d/99-proxy.conf
        info "Файл /etc/apt/apt.conf.d/99-proxy.conf удалён"
    else
        warning "Файл 99-proxy.conf не найден"
    fi

    unset http_proxy https_proxy 2>/dev/null || true
    info "Переменные http_proxy и https_proxy сброшены"
    info "Прокси на Сервере 1 полностью удалён"
}

# ---------- Тест скорости ----------
speed_test() {
    section "Тест скорости скачивания GitHub (без прокси vs через прокси)"
    local TEST_URL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
    local TMP_FILE="/tmp/speedtest_github.tmp"

    # Вспомогательная функция: из "0m5.643s" делает секунды (через awk)
    _parse_time() {
        echo "$1" | awk -F'[ms]' '{ printf "%.3f", ($1 * 60) + $2 }'
    }

    # Тест без прокси
    echo "Тест БЕЗ прокси..."
    local time_direct_raw
    time_direct_raw=$( { time curl -sL --max-time 30 -o "$TMP_FILE" "$TEST_URL"; } 2>&1 | grep real | awk '{print $2}')
    local size_direct
    size_direct=$(stat -c%s "$TMP_FILE" 2>/dev/null || echo "0")
    local time_direct_sec
    time_direct_sec=$(_parse_time "$time_direct_raw")
    rm -f "$TMP_FILE"

    # Тест с прокси (если настроен)
    local time_proxy_raw="N/A"
    local time_proxy_sec=0
    local size_proxy=0
    if [[ -n "${http_proxy:-}" ]]; then
        echo "Тест С прокси ($http_proxy)..."
        time_proxy_raw=$( { time curl -sL --max-time 30 -o "$TMP_FILE" "$TEST_URL"; } 2>&1 | grep real | awk '{print $2}')
        size_proxy=$(stat -c%s "$TMP_FILE" 2>/dev/null || echo "0")
        time_proxy_sec=$(_parse_time "$time_proxy_raw")
        rm -f "$TMP_FILE"
    else
        echo "Прокси не настроен (переменные http_proxy/https_proxy не заданы)."
    fi

    # Расчёт скоростей (Мбит/с) через awk
    local speed_direct_mbps="N/A"
    local speed_proxy_mbps="N/A"
    if [[ "$time_direct_sec" =~ ^[0-9.]+$ ]] && (( $(echo "$time_direct_sec > 0" | bc -l 2>/dev/null || echo "0") )); then
        speed_direct_mbps=$(awk -v size="$size_direct" -v time="$time_direct_sec" 'BEGIN { printf "%.2f", (size * 8) / (time * 1000000) }')
    fi
    if [[ "$time_proxy_sec" =~ ^[0-9.]+$ ]] && (( $(echo "$time_proxy_sec > 0" | bc -l 2>/dev/null || echo "0") )); then
        speed_proxy_mbps=$(awk -v size="$size_proxy" -v time="$time_proxy_sec" 'BEGIN { printf "%.2f", (size * 8) / (time * 1000000) }')
    fi

    echo ""
    echo "Результаты теста скорости:"
    echo "  Без прокси:  ${speed_direct_mbps} Мбит/с  (${size_direct} байт за ${time_direct_sec} сек)"
    if [[ "$time_proxy_sec" =~ ^[0-9.]+$ ]]; then
        echo "  С прокси:    ${speed_proxy_mbps} Мбит/с  (${size_proxy} байт за ${time_proxy_sec} сек)"
        if [[ "$speed_direct_mbps" != "N/A" && "$speed_proxy_mbps" != "N/A" ]]; then
            local ratio
            ratio=$(awk -v srv="$speed_proxy_mbps" -v srd="$speed_direct_mbps" 'BEGIN { printf "%.2f", srv / srd }')
            echo "  Ускорение:   в ${ratio} раза"
        fi
    else
        echo "  С прокси:    N/A"
    fi
    echo ""
    info "Тест завершён"
}

# ---------- Интерактивное меню ----------
show_menu() {
    clear
    echo ""
    echo "============================================"
    echo "  SOCKS5 PROXY MANAGER"
    echo "============================================"
    echo "  1. Настроить прокси (Сервер 2)"
    echo "  2. Настроить прокси (Сервер 1)"
    echo "  3. Удалить прокси (Сервер 2)"
    echo "  4. Удалить прокси (Сервер 1)"
    echo "  5. Проверить скорость соединения"
    echo "  0. Выход"
    echo ""
    read -p "Ваш выбор: " choice
    case "$choice" in
        1)
            read -p "Введите IP-адрес Сервера 1: " ip
            [[ -z "$ip" ]] && error "IP не введён"
            setup_server2 "$ip"
            ;;
        2)
            read -p "Введите IP-адрес Сервера 2: " ip
            [[ -z "$ip" ]] && error "IP не введён"
            setup_server1 "$ip"
            ;;
        3) cleanup_server2 ;;
        4) cleanup_server1 ;;
        5) speed_test ;;
        0) info "Выход."; exit 0 ;;
        *) error "Неверный выбор." ;;
    esac
    echo ""
    read -p "Нажмите Enter для возврата в меню..." dummy
    show_menu
}

# ---------- Обработка аргументов ----------
case "${1:-}" in
    --server2)
        [[ -z "${2:-}" ]] && error "Укажите IP Сервера 1: bash $0 --server2 IP_СЕРВЕРА_1"
        setup_server2 "$2"
        ;;
    --server1)
        [[ -z "${2:-}" ]] && error "Укажите IP Сервера 2: bash $0 --server1 IP_СЕРВЕРА_2"
        setup_server1 "$2"
        ;;
    --cleanup-server2) cleanup_server2 ;;
    --cleanup-server1) cleanup_server1 ;;
    --speedtest) speed_test ;;
    --help|-h)
        echo "Использование:"
        echo "  bash $0                          - интерактивное меню"
        echo "  bash $0 --server2 IP_СЕРВЕРА_1   - настроить прокси на Сервере 2"
        echo "  bash $0 --server1 IP_СЕРВЕРА_2   - настроить прокси на Сервере 1"
        echo "  bash $0 --cleanup-server2        - удалить прокси на Сервере 2"
        echo "  bash $0 --cleanup-server1        - удалить прокси на Сервере 1"
        echo "  bash $0 --speedtest              - тест скорости"
        exit 0
        ;;
    *)
        show_menu
        ;;
esac
