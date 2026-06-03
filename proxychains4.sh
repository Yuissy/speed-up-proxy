#!/usr/bin/env bash
# setup_proxy.sh — SOCKS5 proxy manager + proxychains4 integration
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }

[[ $EUID -eq 0 ]] || error "Запустите от root"

PROXY_CONF="/etc/proxychains4.conf"
APT_PROXY_CONF="/etc/apt/apt.conf.d/99-socks-proxy.conf"
CURL_RC="/root/.curlrc"
WGET_RC="/root/.wgetrc"

###############################################################################
# PROXYCHAINS SETUP
###############################################################################
setup_proxychains_conf() {
    local proxy_ip="$1"
    local proxy_port="${2:-1080}"

    if ! command -v proxychains4 &>/dev/null; then
        apt-get update -qq && apt-get install -y proxychains4
    fi

    backup_existing "$PROXY_CONF"

    cat > "$PROXY_CONF" <<EOF
strict_chain
quiet_mode
# proxy_dns отключён — DNS к CF API резолвится локально,
# попадает в localnet и идёт напрямую
tcp_read_time_out 15000
tcp_connect_time_out 8000

# Cloudflare API — напрямую (без прокси)
localnet 104.16.0.0/12
localnet 172.64.0.0/13
localnet 131.0.72.0/22
# Let's Encrypt
localnet 23.32.0.0/11

[ProxyList]
socks5 ${proxy_ip} ${proxy_port}
EOF

    info "proxychains4.conf записан: socks5://${proxy_ip}:${proxy_port}"
    info "CF API и Let's Encrypt исключены из проксирования"
}

###############################################################################
# APT PROXY
###############################################################################
setup_apt_proxy() {
    local proxy_ip="$1"
    local proxy_port="${2:-1080}"

    cat > "$APT_PROXY_CONF" <<EOF
Acquire::http::Proxy "socks5h://${proxy_ip}:${proxy_port}";
Acquire::https::Proxy "socks5h://${proxy_ip}:${proxy_port}";
EOF
    info "apt прокси настроен"
}

remove_apt_proxy() {
    rm -f "$APT_PROXY_CONF"
    info "apt прокси удалён"
}

###############################################################################
# CURL / WGET
###############################################################################
setup_curl_proxy() {
    local proxy_ip="$1"
    local proxy_port="${2:-1080}"

    # Добавляем прокси в .curlrc если не стоит
    grep -q "^socks5" "$CURL_RC" 2>/dev/null && sed -i '/^socks5/d' "$CURL_RC" 2>/dev/null || true

    cat >> "$CURL_RC" <<EOF
socks5 = ${proxy_ip}:${proxy_port}
EOF
    info "curl прокси настроен (~/.curlrc)"
    warning "CF API (104.16.x.x и др.) НЕ в .curlrc — curl не поддерживает noproxy для SOCKS5 на уровне конфига"
    warning "Для curl к CF API используйте: curl --noproxy 'api.cloudflare.com' ..."
}

remove_curl_proxy() {
    sed -i '/^socks5/d' "$CURL_RC" 2>/dev/null || true
    info "curl прокси удалён"
}

###############################################################################
# SERVER 2: SOCKS5 INBOUND
###############################################################################
setup_server2_socks() {
    local server1_ip="$1"

    section "Настройка SOCKS5 на Сервере 2"

    local XRAY_BIN="/usr/local/bin/xray"
    local CONF="/usr/local/etc/xray/config.json"

    [[ -f "$CONF" ]] || error "Конфиг Xray не найден: $CONF. Сначала установите Xray."

    if jq -e '.inbounds[] | select(.tag == "socks-proxy")' "$CONF" > /dev/null 2>&1; then
        warning "SOCKS5 inbound уже настроен"
        return 0
    fi

    # Добавляем SOCKS5 inbound
    local updated
    updated=$(jq '.inbounds += [{
        "tag": "socks-proxy",
        "listen": "0.0.0.0",
        "port": 1080,
        "protocol": "socks",
        "settings": {
            "auth": "noauth",
            "udp": false
        }
    }]' "$CONF")

    echo "$updated" > "$CONF"
    systemctl restart xray
    info "SOCKS5 inbound добавлен на порт 1080"

    # UFW
    if command -v ufw &>/dev/null; then
        if [[ -n "$server1_ip" ]]; then
            ufw allow from "$server1_ip" to any port 1080 proto tcp \
                comment 'SOCKS5 proxy for Server1'
            info "UFW: порт 1080 открыт только для $server1_ip"
        else
            ufw allow 1080/tcp comment 'SOCKS5 proxy'
            warning "UFW: порт 1080 открыт для всех — ограничьте вручную"
        fi
    fi

    local pub_ip
    pub_ip=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    echo ""
    info "Сервер 2 готов как SOCKS5 прокси."
    info "На Сервере 1 выполните:"
    echo "  bash setup_proxy.sh --setup-server1 ${pub_ip}"
}

###############################################################################
# SERVER 1: FULL PROXY SETUP
###############################################################################
setup_server1_proxy() {
    local server2_ip="$1"
    local proxy_port="${2:-1080}"

    section "Настройка прокси на Сервере 1"

    setup_proxychains_conf "$server2_ip" "$proxy_port"
    setup_apt_proxy "$server2_ip" "$proxy_port"
    setup_curl_proxy "$server2_ip" "$proxy_port"

    # Проверка
    echo
    info "Проверка прокси..."
    if proxychains4 curl -s --max-time 10 https://api.ipify.org 2>/dev/null; then
        echo
        info "✅ Прокси работает"
    else
        warning "⚠️  Проверка не прошла — возможно Сервер 2 недоступен"
    fi

    echo
    info "Прокси настроен. Для установки xray_setup.sh используйте:"
    echo "  proxychains4 bash xray_setup.sh --mode server1"
    echo "  или просто: bash xray_setup.sh --mode server1"
    echo "  (curl и apt уже идут через прокси автоматически)"
}

###############################################################################
# CLEANUP SERVER 1
###############################################################################
cleanup_server1_proxy() {
    section "Удаление прокси настроек на Сервере 1"

    remove_apt_proxy
    remove_curl_proxy

    # proxychains — очищаем ProxyList но оставляем файл
    if [[ -f "$PROXY_CONF" ]]; then
        sed -i '/^socks5/d' "$PROXY_CONF"
        info "proxychains.conf очищен"
    fi

    info "Прокси настройки удалены"
    warning "Если нужно восстановить — запустите --setup-server1 <IP>"
}

###############################################################################
# CLEANUP SERVER 2
###############################################################################
cleanup_server2_socks() {
    section "Удаление SOCKS5 inbound на Сервере 2"

    local CONF="/usr/local/etc/xray/config.json"
    [[ -f "$CONF" ]] || { warning "Конфиг не найден"; return; }

    if command -v jq &>/dev/null; then
        jq 'del(.inbounds[] | select(.tag == "socks-proxy"))' "$CONF" \
            > /tmp/xray_conf_tmp.json && mv /tmp/xray_conf_tmp.json "$CONF"
        systemctl restart xray
        info "SOCKS5 inbound удалён"
    else
        warning "jq не установлен — удалите inbound вручную"
    fi

    # UFW
    local rules
    rules=$(ufw status numbered 2>/dev/null | grep "1080/tcp" | awk '{print $1}' | tr -d '[]' | sort -rn)
    for num in $rules; do
        ufw --force delete "$num" 2>/dev/null || true
    done
    info "UFW правила для 1080 удалены"
}

###############################################################################
# SPEED TEST
###############################################################################
speed_test() {
    section "Тест скорости (GitHub)"

    local test_url="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
    local tmp="/tmp/speedtest_$$.tmp"

    echo "Тест БЕЗ прокси..."
    local t_start t_end size_direct speed_direct
    t_start=$(date +%s%N)
    curl -sL --max-time 30 --noproxy '*' -o "$tmp" "$test_url" 2>/dev/null || true
    t_end=$(date +%s%N)
    size_direct=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    local elapsed_direct
    elapsed_direct=$(awk "BEGIN {printf \"%.3f\", ($t_end - $t_start) / 1000000000}")
    speed_direct=$(awk "BEGIN {printf \"%.2f\", ($size_direct * 8) / ($elapsed_direct * 1000000)}")
    rm -f "$tmp"

    echo "Тест ЧЕРЕЗ proxychains..."
    local t_start2 t_end2 size_proxy speed_proxy
    t_start2=$(date +%s%N)
    proxychains4 curl -sL --max-time 30 -o "$tmp" "$test_url" 2>/dev/null || true
    t_end2=$(date +%s%N)
    size_proxy=$(stat -c%s "$tmp" 2>/dev/null || echo 0)
    local elapsed_proxy
    elapsed_proxy=$(awk "BEGIN {printf \"%.3f\", ($t_end2 - $t_start2) / 1000000000}")
    speed_proxy=$(awk "BEGIN {printf \"%.2f\", ($size_proxy * 8) / ($elapsed_proxy * 1000000)}")
    rm -f "$tmp"

    echo ""
    echo "Результаты:"
    echo "  Без прокси:  ${speed_direct} Мбит/с  (${size_direct} байт за ${elapsed_direct}с)"
    echo "  С прокси:    ${speed_proxy} Мбит/с  (${size_proxy} байт за ${elapsed_proxy}с)"
    if [[ "$speed_proxy" != "0.00" && "$speed_direct" != "0.00" ]]; then
        local ratio
        ratio=$(awk "BEGIN {printf \"%.1f\", $speed_proxy / $speed_direct}")
        echo "  Ускорение:   в ${ratio}x"
    fi
}

###############################################################################
# STATUS
###############################################################################
show_status() {
    section "Статус прокси"

    echo "proxychains4:"
    if [[ -f "$PROXY_CONF" ]] && grep -q "^socks5" "$PROXY_CONF"; then
        grep "^socks5" "$PROXY_CONF"
    else
        echo "  не настроен"
    fi

    echo "apt proxy:"
    [[ -f "$APT_PROXY_CONF" ]] && cat "$APT_PROXY_CONF" || echo "  не настроен"

    echo "curl (.curlrc):"
    grep "^socks5" "$CURL_RC" 2>/dev/null || echo "  не настроен"

    echo "Проверка соединения через прокси:"
    if grep -q "^socks5" "$PROXY_CONF" 2>/dev/null; then
        proxychains4 curl -s --max-time 5 https://api.ipify.org 2>/dev/null \
            && echo " (OK)" || echo " (ОШИБКА)"
    else
        echo "  прокси не настроен"
    fi
}

###############################################################################
# HELPERS
###############################################################################
backup_existing() {
    local f="$1"
    [[ -f "$f" ]] && cp "$f" "${f}.bak.$(date +%s)" && info "Бэкап: ${f}.bak"
}

###############################################################################
# INTERACTIVE MENU
###############################################################################
show_menu() {
    clear
    echo ""
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         SOCKS5 Proxy Manager + Proxychains4         ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  СЕРВЕР 2:                                          ║"
    echo "║  1. Настроить SOCKS5 inbound (Xray)                 ║"
    echo "║  2. Удалить SOCKS5 inbound                          ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  СЕРВЕР 1:                                          ║"
    echo "║  3. Настроить прокси (proxychains + apt + curl)     ║"
    echo "║  4. Удалить прокси настройки                        ║"
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  УТИЛИТЫ:                                           ║"
    echo "║  5. Тест скорости (без прокси vs через прокси)      ║"
    echo "║  6. Статус прокси                                   ║"
    echo "║  0. Выход                                           ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo
    read -rp "Выбор: " choice

    case "$choice" in
        1)
            read -rp "IP Сервера 1 (для ограничения доступа, Enter=все): " s1ip
            setup_server2_socks "${s1ip:-}"
            ;;
        2) cleanup_server2_socks ;;
        3)
            read -rp "IP Сервера 2: " s2ip
            [[ -z "$s2ip" ]] && { warning "IP не введён"; show_menu; return; }
            read -rp "Порт [1080]: " s2port
            setup_server1_proxy "$s2ip" "${s2port:-1080}"
            ;;
        4) cleanup_server1_proxy ;;
        5) speed_test ;;
        6) show_status ;;
        0) exit 0 ;;
        *) warning "Неверный выбор" ;;
    esac

    echo
    read -rp "Нажмите Enter для возврата в меню..." _
    show_menu
}

###############################################################################
# MAIN
###############################################################################
case "${1:-menu}" in
    --setup-server2)
        setup_server2_socks "${2:-}"
        ;;
    --setup-server1)
        [[ -n "${2:-}" ]] || error "Укажите IP Сервера 2: --setup-server1 <IP> [port]"
        setup_server1_proxy "$2" "${3:-1080}"
        ;;
    --cleanup-server1) cleanup_server1_proxy ;;
    --cleanup-server2) cleanup_server2_socks ;;
    --speedtest)       speed_test ;;
    --status)          show_status ;;
    menu|"")           show_menu ;;
    -h|--help)
        echo "Использование:"
        echo "  $0                              — интерактивное меню"
        echo "  $0 --setup-server2 [IP_S1]      — настроить SOCKS5 на Сервере 2"
        echo "  $0 --setup-server1 IP_S2 [port] — настроить прокси на Сервере 1"
        echo "  $0 --cleanup-server1            — удалить прокси настройки"
        echo "  $0 --cleanup-server2            — удалить SOCKS5 inbound"
        echo "  $0 --speedtest                  — тест скорости"
        echo "  $0 --status                     — статус прокси"
        ;;
    *) error "Неизвестный аргумент: $1. Используйте --help" ;;
esac
