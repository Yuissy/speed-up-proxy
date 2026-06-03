#!/usr/bin/env bash
# xray_update.sh — Emergency обновление Xray-core
# Поддержка: stable, prerelease, конкретная версия
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }

[[ $EUID -eq 0 ]] || error "Запустите от root"

XRAY_BIN="/usr/local/bin/xray"
XRAY_BAK="/usr/local/bin/xray.bak"
LOG="/var/log/xray-cascade/update.log"
PROXY_CONF="/etc/proxychains4.conf"

mkdir -p "$(dirname "$LOG")"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [xray_update] $*" | tee -a "$LOG"; }

###############################################################################
get_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "64" ;;
        aarch64) echo "arm64-v8a" ;;
        *)       error "Неподдерживаемая архитектура: $arch" ;;
    esac
}

current_version() {
    "$XRAY_BIN" version 2>/dev/null | grep -oP 'Xray \K[\d.]+' | head -1 || echo "неизвестно"
}

get_release_url() {
    local release_type="$1"  # latest | prerelease | vX.X.X
    local arch
    arch=$(get_arch)
    local api_url asset_name="Xray-linux-${arch}.zip"

    case "$release_type" in
        latest)
            api_url="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
            curl -s "$api_url" | jq -r ".assets[] | select(.name==\"${asset_name}\") | .browser_download_url"
            ;;
        prerelease)
            api_url="https://api.github.com/repos/XTLS/Xray-core/releases?per_page=10"
            curl -s "$api_url" | jq -r \
                "[.[] | select(.prerelease==true)][0].assets[] | select(.name==\"${asset_name}\") | .browser_download_url"
            ;;
        v*)
            echo "https://github.com/XTLS/Xray-core/releases/download/${release_type}/${asset_name}"
            ;;
    esac
}

get_release_version() {
    local release_type="$1"
    case "$release_type" in
        latest)
            curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
                | jq -r '.tag_name'
            ;;
        prerelease)
            curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=10" \
                | jq -r '[.[] | select(.prerelease==true)][0].tag_name'
            ;;
        v*)
            echo "$release_type"
            ;;
    esac
}

use_proxychains() {
    [[ -f "$PROXY_CONF" ]] && grep -q "^socks5" "$PROXY_CONF" 2>/dev/null
}

do_download() {
    local url="$1"
    local dest="$2"
    if use_proxychains; then
        info "Загрузка через proxychains..."
        proxychains4 curl -sL --max-time 180 -o "$dest" "$url"
    else
        curl -sL --max-time 180 -o "$dest" "$url"
    fi
}

do_update() {
    local release_type="$1"

    section "Получение информации о версии"

    local current new_version url
    current=$(current_version)
    info "Текущая версия: $current"

    info "Получаем информацию о релизе..."
    new_version=$(get_release_version "$release_type")
    url=$(get_release_url "$release_type")

    [[ -n "$url" && "$url" != "null" ]] || error "Не удалось получить URL для версии: $release_type"

    info "Целевая версия: $new_version"
    info "URL: $url"

    echo
    read -rp "Обновить Xray $current → $new_version? [Y/n]: " confirm
    [[ "${confirm,,}" == "n" ]] && { info "Отменено."; exit 0; }

    section "Загрузка Xray $new_version"

    local tmp_dir
    tmp_dir=$(mktemp -d)
    trap "rm -rf $tmp_dir" EXIT

    do_download "$url" "$tmp_dir/xray.zip"
    unzip -o "$tmp_dir/xray.zip" -d "$tmp_dir" > /dev/null

    [[ -f "$tmp_dir/xray" ]] || error "xray бинарник не найден в архиве"

    section "Установка"

    # Бэкап текущего
    cp -f "$XRAY_BIN" "$XRAY_BAK"
    info "Бэкап: $XRAY_BAK"

    cp -f "$tmp_dir/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"

    local installed_version
    installed_version=$(current_version)
    info "Установлена версия: $installed_version"

    section "Перезапуск Xray"

    if systemctl restart xray; then
        sleep 2
        if systemctl is-active --quiet xray; then
            info "✅ Xray запущен успешно"
            log "Обновление: $current → $installed_version (тип: $release_type)"
        else
            warning "❌ Xray не запустился после обновления, откат..."
            rollback
        fi
    else
        warning "❌ Ошибка при перезапуске, откат..."
        rollback
    fi
}

rollback() {
    if [[ -f "$XRAY_BAK" ]]; then
        cp -f "$XRAY_BAK" "$XRAY_BIN"
        chmod +x "$XRAY_BIN"
        systemctl restart xray
        info "Откат выполнен: $(current_version)"
        log "Откат к предыдущей версии"
    else
        error "Бэкап не найден: $XRAY_BAK"
    fi
}

show_menu() {
    clear
    echo
    echo "╔══════════════════════════════════════════════════════╗"
    echo "║         Xray Emergency Update                       ║"
    echo "╠══════════════════════════════════════════════════════╣"
    printf "║  Текущая версия: %-35s║\n" "$(current_version)"
    if use_proxychains; then
        local proxy_line
        proxy_line=$(grep "^socks5" "$PROXY_CONF" | head -1)
        printf "║  Прокси: %-43s║\n" "$proxy_line"
    else
        echo "║  Прокси: не настроен (прямое подключение)           ║"
    fi
    echo "╠══════════════════════════════════════════════════════╣"
    echo "║  1. Stable (последний стабильный релиз)              ║"
    echo "║  2. Pre-release (крайняя необходимость)              ║"
    echo "║  3. Конкретная версия (например v25.3.6)             ║"
    echo "║  4. Откат к предыдущей версии                        ║"
    echo "║  5. Проверить доступные версии                       ║"
    echo "║  0. Выход                                            ║"
    echo "╚══════════════════════════════════════════════════════╝"
    echo
    read -rp "Выбор: " choice

    case "$choice" in
        1) do_update "latest" ;;
        2)
            warning "Pre-release может содержать баги. Используйте только при необходимости."
            read -rp "Подтвердите [y/N]: " pre_confirm
            [[ "${pre_confirm,,}" == "y" ]] && do_update "prerelease" || info "Отменено."
            ;;
        3)
            read -rp "Введите версию (например v25.3.6): " ver
            [[ "$ver" =~ ^v[0-9] ]] || { warning "Неверный формат версии"; exit 1; }
            do_update "$ver"
            ;;
        4) rollback ;;
        5)
            section "Последние версии"
            info "Stable:"
            curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
                | jq -r '"\(.tag_name) — \(.published_at[:10])"'
            info "Pre-releases (последние 3):"
            curl -s "https://api.github.com/repos/XTLS/Xray-core/releases?per_page=10" \
                | jq -r '[.[] | select(.prerelease==true)][:3][] | "\(.tag_name) — \(.published_at[:10])"'
            echo
            read -rp "Нажмите Enter для возврата..." _
            show_menu
            ;;
        0) exit 0 ;;
        *) warning "Неверный выбор"; show_menu ;;
    esac
}

###############################################################################
# MAIN
###############################################################################
case "${1:-menu}" in
    --stable)     do_update "latest" ;;
    --prerelease) do_update "prerelease" ;;
    --version)    [[ -n "${2:-}" ]] && do_update "$2" || error "Укажите версию: --version v25.3.6" ;;
    --rollback)   rollback ;;
    menu|"")      show_menu ;;
    -h|--help)
        echo "Использование: $0 [--stable|--prerelease|--version vX.X.X|--rollback]"
        echo "Без аргументов — интерактивное меню"
        ;;
    *) error "Неизвестный аргумент: $1" ;;
esac
