#!/usr/bin/env bash
# xray_setup.sh — Xray cascade setup (Server 1 / Server 2)
# No panel, pure Xray + Nginx
set -euo pipefail

###############################################################################
# COLORS & OUTPUT
###############################################################################
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}=== $* ===${NC}"; }
question(){ echo -e "${YELLOW}[?]${NC} $*"; }

###############################################################################
# CONSTANTS
###############################################################################
XRAY_BIN="/usr/local/bin/xray"
XRAY_CONF="/usr/local/etc/xray/config.json"
XRAY_CONF_DIR="/usr/local/etc/xray"
XRAY_LOG_DIR="/var/log/xray"
NGINX_CONF_DIR="/etc/nginx/conf.d"
NGINX_LOCATIONS="/etc/nginx/locations"
SCRIPT_DIR="/usr/local/xray-cascade"
LOGROTATE_CONF="/etc/logrotate.d/xray-cascade"
BACKUP_DIR="/root/xray-cascade-backup"

###############################################################################
# HELPERS
###############################################################################
require_root() {
    [[ $EUID -eq 0 ]] || error "Запустите от root"
}

generate_uuid() {
    if command -v xray &>/dev/null; then
        xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

generate_path() {
    openssl rand -hex 12
}

random_port() {
    local port
    while true; do
        port=$(shuf -i 10000-60000 -n 1)
        if ! ss -tlnp 2>/dev/null | grep -q ":$port "; then
            echo "$port"
            return
        fi
    done
}

check_dns() {
    local domain="$1"
    local expected_ip="$2"
    local resolved
    resolved=$(dig +short A "$domain" 2>/dev/null | head -1)
    if [[ "$resolved" == "$expected_ip" ]]; then
        info "DNS: $domain → $resolved ✓"
        return 0
    else
        warning "DNS: $domain → $resolved (ожидался $expected_ip)"
        return 1
    fi
}

get_public_ip() {
    curl -s --max-time 5 --noproxy '*' https://api.ipify.org 2>/dev/null \
        || curl -s --max-time 5 --noproxy '*' https://ifconfig.me 2>/dev/null \
        || ip route get 8.8.8.8 | grep -oP 'src \K\S+'
}

backup_file() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    mkdir -p "$BACKUP_DIR"
    cp "$f" "$BACKUP_DIR/$(basename "$f").$(date +%s).bak"
    info "Забэкаплен: $f"
}

###############################################################################
# DEPENDENCIES
###############################################################################
install_dependencies() {
    section "Установка зависимостей"
    export DEBIAN_FRONTEND=noninteractive
    export NEEDRESTART_MODE=a

    apt-get update -qq

    local pkgs=(
        curl wget unzip jq openssl sqlite3
        ufw fail2ban ca-certificates gnupg
        python3 proxychains4
        nano dnsutils net-tools iproute2
        tcpdump mtr ncat htop logrotate
        certbot python3-certbot-dns-cloudflare
    )

    local to_install=()
    for pkg in "${pkgs[@]}"; do
        dpkg -l "$pkg" &>/dev/null || to_install+=("$pkg")
    done

    if [[ ${#to_install[@]} -gt 0 ]]; then
        info "Устанавливаем: ${to_install[*]}"
        apt-get install -y "${to_install[@]}" 2>/dev/null
    else
        info "Все зависимости уже установлены"
    fi
}

###############################################################################
# XRAY INSTALL
###############################################################################
install_xray() {
    section "Установка Xray-core"

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  arch="64" ;;
        aarch64) arch="arm64-v8a" ;;
        *)       error "Неподдерживаемая архитектура: $arch" ;;
    esac

    local url
    url=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | jq -r ".assets[] | select(.name==\"Xray-linux-${arch}.zip\") | .browser_download_url")

    [[ -n "$url" ]] || error "Не удалось получить URL Xray"

    local tmp_dir="/tmp/xray_install_$$"
    mkdir -p "$tmp_dir"

    info "Скачиваем Xray: $url"
    curl -L --max-time 120 -o "$tmp_dir/xray.zip" "$url"
    unzip -o "$tmp_dir/xray.zip" -d "$tmp_dir" > /dev/null

    [[ -f "$tmp_dir/xray" ]] || error "xray бинарник не найден в архиве"

    cp -f "$tmp_dir/xray" "$XRAY_BIN"
    chmod +x "$XRAY_BIN"
    rm -rf "$tmp_dir"

    info "Xray установлен: $("$XRAY_BIN" version | head -1)"
}

###############################################################################
# XRAY SERVICE
###############################################################################
setup_xray_service() {
    section "Настройка systemd сервиса Xray"

    mkdir -p "$XRAY_CONF_DIR" "$XRAY_LOG_DIR"

    cat > /etc/systemd/system/xray.service <<'EOF'
[Unit]
Description=Xray Service
Documentation=https://github.com/xtls
After=network.target nss-lookup.target

[Service]
User=root
ExecStart=/usr/local/bin/xray run -confdir /usr/local/etc/xray/
Restart=on-failure
RestartPreventExitStatus=23
LimitNPROC=10000
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
}

###############################################################################
# NGINX INSTALL
###############################################################################
install_nginx() {
    section "Установка Nginx"

    if ! command -v nginx &>/dev/null; then
        apt-get install -y nginx
    fi

    mkdir -p "$NGINX_LOCATIONS"

    # Основной nginx.conf
    backup_file /etc/nginx/nginx.conf
    cat > /etc/nginx/nginx.conf <<'EOF'
user www-data;
worker_processes auto;
worker_rlimit_nofile 65535;
pid /var/run/nginx.pid;
error_log /var/log/nginx/error.log warn;

events {
    multi_accept on;
    worker_connections 4096;
}

http {
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    server_tokens off;
    keepalive_timeout 75s;
    keepalive_requests 1000;
    client_max_body_size 16M;

    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;

    resolver 1.1.1.1 8.8.8.8 valid=60s;
    resolver_timeout 2s;

    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    include /etc/nginx/conf.d/*.conf;
}
EOF

    systemctl enable nginx
}

###############################################################################
# TLS CERTIFICATE
###############################################################################
issue_certificate() {
    local domain="$1"
    local email="$2"
    local cf_token="${3:-}"

    section "Выпуск TLS сертификата"

    if [[ -f "/etc/letsencrypt/live/${domain}/fullchain.pem" ]]; then
        info "Сертификат уже существует для $domain"
        return 0
    fi

    if [[ -n "$cf_token" ]]; then
        info "Выпуск через DNS challenge (Cloudflare)"
        local cf_creds="/etc/letsencrypt/.cloudflare.credentials"
        touch "$cf_creds"
        chmod 600 "$cf_creds"
        if [[ "$cf_token" =~ [A-Z] ]]; then
            echo "dns_cloudflare_api_token = ${cf_token}" > "$cf_creds"
        else
            echo "dns_cloudflare_api_key = ${cf_token}" > "$cf_creds"
        fi
        certbot certonly \
            --dns-cloudflare \
            --dns-cloudflare-credentials "$cf_creds" \
            --dns-cloudflare-propagation-seconds 30 \
            --rsa-key-size 4096 \
            -d "${domain},*.${domain}" \
            --agree-tos -m "$email" \
            --cert-name "$domain" \
            --no-eff-email --non-interactive
    else
        info "Выпуск через HTTP challenge (standalone)"
        systemctl stop nginx 2>/dev/null || true
        certbot certonly \
            --standalone \
            -d "$domain" \
            --agree-tos -m "$email" \
            --no-eff-email --non-interactive
        systemctl start nginx 2>/dev/null || true
    fi

    # Автообновление
    if ! crontab -l 2>/dev/null | grep -q "certbot renew"; then
        (crontab -l 2>/dev/null; echo "0 3 1 */2 * certbot -q renew --post-hook 'systemctl reload nginx'") | crontab -
    fi

    info "Сертификат выпущен: /etc/letsencrypt/live/${domain}/"
}

###############################################################################
# BBR
###############################################################################
setup_bbr() {
    section "Включение BBR"
    if ! grep -q "tcp_congestion_control = bbr" /etc/sysctl.conf 2>/dev/null; then
        cat >> /etc/sysctl.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
        sysctl -p > /dev/null 2>&1
    fi
    info "BBR: $(sysctl -n net.ipv4.tcp_congestion_control)"
}

###############################################################################
# FAIL2BAN
###############################################################################
setup_fail2ban() {
    local mode="${1:-server1}"
    section "Настройка Fail2ban"

    if [[ "$mode" == "server2" ]]; then
        cat > /etc/fail2ban/jail.d/xray-cascade.conf <<'EOF'
[DEFAULT]
bantime.increment = true
bantime.multiplier = 2
bantime.maxtime = 604800
bantime.overalljails = true

[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 3
bantime = 3600
findtime = 600
EOF
    else
        cat > /etc/fail2ban/jail.d/xray-cascade.conf <<'EOF'
[DEFAULT]
bantime.increment = true
bantime.multiplier = 2
bantime.maxtime = 604800
bantime.overalljails = true

[sshd]
enabled = true
port = ssh
backend = systemd
maxretry = 3
bantime = 3600
findtime = 600

[nginx-limit-req]
enabled = true
port = http,https
logpath = /var/log/nginx/error.log
maxretry = 10
bantime = 3600
findtime = 600

[nginx-botsearch]
enabled = true
port = http,https
logpath = /var/log/nginx/access.log
maxretry = 5
bantime = 86400
findtime = 3600
EOF
    fi

    systemctl enable fail2ban
    systemctl restart fail2ban || true
    info "Fail2ban настроен"
}

###############################################################################
# AUTO UPDATES
###############################################################################
setup_auto_updates() {
    section "Настройка автообновлений"

    apt-get install -y unattended-upgrades > /dev/null 2>&1
    echo unattended-upgrades unattended-upgrades/enable_auto_updates boolean true \
        | debconf-set-selections
    dpkg-reconfigure -f noninteractive unattended-upgrades 2>/dev/null

    # Скрипт автообновления Xray
    mkdir -p "$SCRIPT_DIR"
    cat > "$SCRIPT_DIR/auto_update_xray.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Автообновление Xray-core (stable)
set -euo pipefail
LOG="/var/log/xray-cascade/update.log"
mkdir -p "$(dirname "$LOG")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

CURRENT=$(/usr/local/bin/xray version 2>/dev/null | grep -oP 'Xray \K[\d.]+' | head -1)
LATEST=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
    | jq -r '.tag_name' | tr -d 'v')

if [[ "$CURRENT" == "$LATEST" ]]; then
    log "Xray уже актуален: $CURRENT"
    exit 0
fi

log "Обновление Xray: $CURRENT → $LATEST"
ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && ARCH="64" || ARCH="arm64-v8a"
URL=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
    | jq -r ".assets[] | select(.name==\"Xray-linux-${ARCH}.zip\") | .browser_download_url")

TMP=$(mktemp -d)
curl -sL --max-time 120 -o "$TMP/xray.zip" "$URL"
unzip -o "$TMP/xray.zip" -d "$TMP" > /dev/null
cp -f /usr/local/bin/xray /usr/local/bin/xray.bak
cp -f "$TMP/xray" /usr/local/bin/xray
chmod +x /usr/local/bin/xray
rm -rf "$TMP"
systemctl restart xray
log "Xray обновлён до $LATEST"
SCRIPT
    chmod +x "$SCRIPT_DIR/auto_update_xray.sh"

    # Скрипт обновления geo файлов
    cat > "$SCRIPT_DIR/update_geo.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
LOG="/var/log/xray-cascade/update.log"
log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

GEO_DIR="/usr/local/share/xray"
mkdir -p "$GEO_DIR"

for file in geoip.dat geosite.dat; do
    URL="https://github.com/v2fly/v2ray-rules-dat/releases/latest/download/${file}"
    if curl -sL --max-time 60 -o "$GEO_DIR/${file}.tmp" "$URL"; then
        mv "$GEO_DIR/${file}.tmp" "$GEO_DIR/${file}"
        log "Обновлён: $file"
    else
        rm -f "$GEO_DIR/${file}.tmp"
        log "Ошибка обновления: $file"
    fi
done

systemctl reload xray 2>/dev/null || systemctl restart xray
SCRIPT
    chmod +x "$SCRIPT_DIR/update_geo.sh"

    # Cron
    apt-get install -y cron
    systemctl enable cron
    systemctl start cron
    local cron_xray="0 4 * * 6 $SCRIPT_DIR/auto_update_xray.sh >> /var/log/xray-cascade/update.log 2>&1"
    local cron_geo="0 3 * * 0 $SCRIPT_DIR/update_geo.sh >> /var/log/xray-cascade/update.log 2>&1"

    (crontab -l 2>/dev/null || true; echo "$cron_xray"; echo "$cron_geo") | crontab -

    info "Автообновление настроено (Xray — суббота 04:00, geo — воскресенье 03:00)"
}

###############################################################################
# LOG ROTATION
###############################################################################
setup_logrotate() {
    section "Настройка ротации логов"

    mkdir -p "$XRAY_LOG_DIR"

    cat > "$LOGROTATE_CONF" <<EOF
$XRAY_LOG_DIR/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        systemctl kill -s USR1 xray 2>/dev/null || true
    endscript
}

/var/log/nginx/*.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
    postrotate
        nginx -s reopen 2>/dev/null || true
    endscript
}
EOF

    info "Logrotate настроен: хранение 7 дней, ежедневная ротация"
}

###############################################################################
# PROXYCHAINS
###############################################################################
setup_proxychains() {
    local proxy_ip="$1"
    local proxy_port="${2:-1080}"

    section "Настройка proxychains4"

    backup_file /etc/proxychains4.conf

    cat > /etc/proxychains4.conf <<EOF
strict_chain
# proxy_dns — отключено, чтобы CF API шёл напрямую
quiet_mode
tcp_read_time_out 15000
tcp_connect_time_out 8000

# Cloudflare API — напрямую (без прокси)
localnet 104.16.0.0/12
localnet 172.64.0.0/13
localnet 131.0.72.0/22

[ProxyList]
socks5 ${proxy_ip} ${proxy_port}
EOF

    info "Proxychains настроен: socks5://${proxy_ip}:${proxy_port}"
    info "Cloudflare API исключён из проксирования"
}

###############################################################################
# NFTABLES / UFW
###############################################################################
setup_firewall() {
    local mode="$1"          # server1 | server2
    local extra_port="${2:-0}"
    local server1_ip="${3:-}"

    section "Настройка файрвола (UFW)"

    ufw --force reset > /dev/null
    ufw default deny incoming > /dev/null
    ufw default allow outgoing > /dev/null

    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
    ssh_port="${ssh_port:-22}"

    ufw limit "${ssh_port}/tcp" comment 'SSH'

    if [[ "$mode" == "server1" ]]; then
        ufw allow 80/tcp comment 'HTTP (certbot)'
        ufw allow 443/tcp comment 'HTTPS (Nginx)'
        if [[ "$extra_port" -gt 0 ]]; then
            ufw allow "${extra_port}/tcp" comment 'Reality reserve'
        fi
        info "Открыты порты: $ssh_port, 80, 443${extra_port:+, $extra_port}"
    elif [[ "$mode" == "server2" ]]; then
        if [[ -n "$server1_ip" ]]; then
            ufw allow from "$server1_ip" to any port "$extra_port" proto tcp \
                comment 'Xray cascade from Server1'
            info "Открыт порт $extra_port только для $server1_ip"
        else
            ufw allow "${extra_port}/tcp" comment 'Xray cascade'
        fi
    fi

    ufw --force enable > /dev/null
    info "UFW включён"
}

###############################################################################
# GEO FILES
###############################################################################
install_geo_files() {
    section "Установка geo файлов"
    mkdir -p /usr/local/share/xray
    "$SCRIPT_DIR/update_geo.sh" || true
}

###############################################################################
# SERVER 2 — RELAY CONFIG
###############################################################################
configure_server2() {
    local listen_port="$1"
    local uuid="$2"
    local xhttp_path="$3"

    section "Конфигурация Xray (Сервер 2 — relay)"

    mkdir -p "$XRAY_CONF_DIR"

    cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log",
    "loglevel": "warning",
    "dnsLog": false
  },
  "inbounds": [
    {
      "tag": "cascade-in",
      "port": ${listen_port},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${uuid}", "flow": "" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${xhttp_path}",
          "mode": "packet-up",
          "noSSEHeader": false,
          "scMaxBufferedPosts": 30,
          "scMaxEachPostBytes": "500000-1000000",
          "scMinPostsIntervalMs": "50-150",
          "xPaddingBytes": "16-64",
          "xPaddingObfsMode": true,
          "xPaddingPlacement": "query",
          "xPaddingMethod": "tokenish",
          "uplinkDataPlacement": "body",
          "xmux": {
            "maxConnections": "1",
            "cMaxReuseTimes": "0",
            "hMaxRequestTimes": "300-600",
            "hMaxReusableSecs": "900-1800",
            "hKeepAlivePeriod": 0
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "network": "udp",
        "port": 53,
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": [
          "domain:ifconfig.me",
          "domain:ipinfo.io",
          "domain:2ip.ru",
          "domain:ipify.org",
          "domain:icanhazip.com"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "direct"
      }
    ]
  }
}
EOF

    info "Конфиг Сервера 2 записан"
}

###############################################################################
# SERVER 1 — XRAY CONFIG
###############################################################################
configure_server1_xray() {
    local client_uuid="$1"
    local xhttp_path="$2"
    local server2_ip="$3"
    local server2_port="$4"
    local server2_uuid="$5"
    local server2_path="$6"
    local reality_port="$7"
    local reality_private_key="$8"
    local reality_public_key="$9"
    local reality_short_id="${10}"
    local domain="${11}"

    section "Конфигурация Xray (Сервер 1)"

    mkdir -p "$XRAY_CONF_DIR"

    # Генерация shortIds
    local sid1 sid2 sid3
    sid1=$(openssl rand -hex 2)
    sid2=$(openssl rand -hex 4)
    sid3=$(openssl rand -hex 8)

    cat > "$XRAY_CONF" <<EOF
{
  "log": {
    "access": "${XRAY_LOG_DIR}/access.log",
    "error": "${XRAY_LOG_DIR}/error.log",
    "loglevel": "warning",
    "dnsLog": false
  },
  "inbounds": [
    {
      "tag": "inbound-xhttp",
      "port": 10000,
      "listen": "127.0.0.1",
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${client_uuid}", "flow": "" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${xhttp_path}",
          "mode": "packet-up",
          "noSSEHeader": false,
          "scMaxBufferedPosts": 30,
          "scMaxEachPostBytes": "500000-1000000",
          "scMinPostsIntervalMs": "50-150",
          "xPaddingBytes": "16-64",
          "xPaddingObfsMode": true,
          "xPaddingPlacement": "query",
          "xPaddingMethod": "tokenish",
          "uplinkDataPlacement": "body",
          "xmux": {
            "maxConnections": "1",
            "cMaxReuseTimes": "0",
            "hMaxRequestTimes": "300-600",
            "hMaxReusableSecs": "900-1800",
            "hKeepAlivePeriod": 0
          },
          "headers": {
            "Server": "nginx/1.25.0",
            "Content-Type": "text/html; charset=UTF-8"
          }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": false
      }
    },
    {
      "tag": "inbound-reality",
      "port": ${reality_port},
      "listen": "0.0.0.0",
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "$(generate_uuid)",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "127.0.0.1:443",
          "serverNames": ["${domain}"],
          "privateKey": "${reality_private_key}",
          "shortIds": ["${sid1}", "${sid2}", "${sid3}"],
          "settings": {
            "publicKey": "${reality_public_key}",
            "fingerprint": "firefox",
            "serverName": "",
            "spiderX": "/"
          }
        },
        "tcpSettings": {
          "acceptProxyProtocol": false,
          "header": { "type": "none" }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls"],
        "routeOnly": true
      }
    }
  ],
  "outbounds": [
    {
      "tag": "cascade",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${server2_ip}",
            "port": ${server2_port},
            "users": [
              { "id": "${server2_uuid}", "encryption": "none" }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "none",
        "xhttpSettings": {
          "path": "${server2_path}",
          "mode": "packet-up",
          "noSSEHeader": false,
          "xPaddingObfsMode": true,
          "xPaddingPlacement": "query",
          "xPaddingMethod": "tokenish",
          "uplinkDataPlacement": "body",
          "xmux": {
            "maxConnections": "1",
            "cMaxReuseTimes": "0",
            "hMaxRequestTimes": "300-600",
            "hMaxReusableSecs": "900-1800",
            "hKeepAlivePeriod": 0
          }
        }
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "network": "udp",
        "port": 53,
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "ip": ["geoip:private"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "domain": [
          "domain:ifconfig.me",
          "domain:ipinfo.io",
          "domain:2ip.ru",
          "domain:ipify.org",
          "domain:icanhazip.com"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "protocol": ["bittorrent"],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": [
          "geosite:category-ads-all"
        ],
        "outboundTag": "blocked"
      },
      {
        "type": "field",
        "domain": ["ext:geosite_RU.dat:ru-blocked"],
        "outboundTag": "cascade"
      },
      {
        "type": "field",
        "ip": ["geoip:ru"],
        "outboundTag": "direct"
      },
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "cascade"
      }
    ]
  }
}
EOF

    info "Конфиг Сервера 1 (Xray) записан"
}

###############################################################################
# SERVER 1 — NGINX CONFIG
###############################################################################
configure_server1_nginx() {
    local domain="$1"
    local xhttp_path="$2"

    section "Конфигурация Nginx (Сервер 1)"

    backup_file "$NGINX_CONF_DIR/xray-cascade.conf"

    # Создаём сайт-заглушку
    mkdir -p /var/www/html
    cat > /var/www/html/index.html <<'STUB'
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Welcome</title>
<style>
body{margin:0;min-height:100vh;display:grid;place-items:center;
font-family:Arial,sans-serif;background:#f4f6f8;color:#1f2937}
main{max-width:640px;padding:32px;text-align:center}
h1{font-size:28px;margin:0 0 12px}
p{margin:0;color:#6b7280}
</style>
</head>
<body><main><h1>Welcome</h1><p>The service is running.</p></main></body>
</html>
STUB

    cat > "$NGINX_CONF_DIR/xray-cascade.conf" <<EOF
# HTTP → HTTPS redirect
server {
    listen 80 default_server;
    server_name _;
    return 301 https://\$host\$request_uri;
}

# HTTPS main
server {
    listen 443 ssl;
    http2 on;
    server_name ${domain} *.${domain};

    ssl_certificate     /etc/letsencrypt/live/${domain}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${domain}/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/${domain}/chain.pem;

    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_session_timeout 1d;
    ssl_session_cache shared:SSL:10m;
    ssl_session_tickets off;
    ssl_prefer_server_ciphers off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "no-referrer-when-downgrade" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;

    root /var/www/html;
    index index.html;

    # XHTTP tunnel
    location ${xhttp_path} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_cache off;
        chunked_transfer_encoding off;
        client_max_body_size 0;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 3600s;
        proxy_send_timeout 3600s;
        proxy_connect_timeout 60s;
        add_header Cache-Control "no-store" always;
        add_header CDN-Cache-Control "no-store" always;
    }

    # Static site (fallback / self-steal)
    location / {
        try_files \$uri \$uri/ =404;
    }

    error_page 400 402 403 404 500 502 503 504 /index.html;
}

# Default server — reject unknown SNI
server {
    listen 443 ssl default_server;
    ssl_reject_handshake on;
}
EOF

    nginx -t && systemctl reload nginx
    info "Nginx настроен"
}

###############################################################################
# LOG LEVEL SWITCHER
###############################################################################
setup_log_switcher() {
    section "Установка утилиты переключения уровня логов"

    cat > "$SCRIPT_DIR/xray_log.sh" <<'SCRIPT'
#!/usr/bin/env bash
# Переключение уровня логов Xray
# Использование: xray_log.sh [warning|info|debug|none]
CONF="/usr/local/etc/xray/config.json"

current=$(jq -r '.log.loglevel' "$CONF")
target="${1:-}"

if [[ -z "$target" ]]; then
    echo "Текущий уровень логов: $current"
    echo "Использование: $0 [none|warning|info|debug]"
    exit 0
fi

case "$target" in
    none|warning|info|debug) ;;
    *) echo "Неверный уровень: $target"; exit 1 ;;
esac

jq ".log.loglevel = \"$target\"" "$CONF" > /tmp/xray_conf_tmp.json
mv /tmp/xray_conf_tmp.json "$CONF"
systemctl restart xray
echo "Уровень логов изменён: $current → $target"
SCRIPT
    chmod +x "$SCRIPT_DIR/xray_log.sh"
    ln -sf "$SCRIPT_DIR/xray_log.sh" /usr/local/bin/xray-log

    info "Утилита xray-log установлена (xray-log [none|warning|info|debug])"
}

###############################################################################
# VERIFY
###############################################################################
verify_server1() {
    local domain="$1"
    local xhttp_path="$2"
    local reality_port="$3"

    section "Проверка установки (Сервер 1)"
    local ok=true

    systemctl is-active --quiet xray && info "✅ Xray запущен" || { warning "❌ Xray не запущен"; ok=false; }
    systemctl is-active --quiet nginx && info "✅ Nginx запущен" || { warning "❌ Nginx не запущен"; ok=false; }

    ss -tlnp | grep -q ":443 " && info "✅ Порт 443 слушает" || { warning "❌ Порт 443 не слушает"; ok=false; }
    ss -tlnp | grep -q ":10000 " && info "✅ Xray XHTTP слушает :10000" || { warning "❌ Xray не слушает :10000"; ok=false; }

    local http_code
    http_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
        "https://${domain}/" 2>/dev/null || echo "000")
    if [[ "$http_code" == "200" ]]; then
        info "✅ Сайт-заглушка отвечает: HTTP $http_code"
    else
        warning "⚠️  Сайт отвечает: HTTP $http_code"
    fi

    http_code=$(curl -sk --max-time 5 -o /dev/null -w "%{http_code}" \
        "https://${domain}${xhttp_path}" 2>/dev/null || echo "000")
    [[ "$http_code" =~ ^(400|404)$ ]] && info "✅ XHTTP путь отвечает: HTTP $http_code (ожидаемо)" \
        || warning "⚠️  XHTTP путь: HTTP $http_code"

    if [[ "$reality_port" -gt 0 ]]; then
        ss -tlnp | grep -q ":${reality_port} " \
            && info "✅ Reality слушает :${reality_port}" \
            || warning "⚠️  Reality не слушает :${reality_port}"
    fi

    $ok && info "Проверка пройдена" || warning "Есть проблемы, проверьте логи: journalctl -u xray -n 50"
}

verify_server2() {
    local port="$1"
    section "Проверка установки (Сервер 2)"

    systemctl is-active --quiet xray && info "✅ Xray запущен" || warning "❌ Xray не запущен"
    ss -tlnp | grep -q ":${port} " && info "✅ Xray слушает :${port}" || warning "❌ Xray не слушает :${port}"
}

###############################################################################
# PRINT CLIENT CONFIG
###############################################################################
print_client_config() {
    local domain="$1"
    local xhttp_path="$2"
    local client_uuid="$3"
    local reality_port="$4"
    local reality_uuid="$5"
    local reality_public_key="$6"
    local reality_short_id="$7"
    local server1_ip="$8"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║              ДАННЫЕ ДЛЯ КЛИЕНТА — СОХРАНИ!                  ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  [XHTTP — основной]                                          ║"
    echo "║  Адрес:    ${domain}"
    echo "║  Порт:     443"
    echo "║  UUID:     ${client_uuid}"
    echo "║  Путь:     ${xhttp_path}"
    echo "║  Протокол: VLESS + XHTTP (packet-up) + TLS"
    echo "║  SNI:      ${domain}"
    echo "║  Mode:     packet-up"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  [Reality — резервный]                                       ║"
    echo "║  Адрес:    ${server1_ip}"
    echo "║  Порт:     ${reality_port}"
    echo "║  UUID:     ${reality_uuid}"
    echo "║  Flow:     xtls-rprx-vision"
    echo "║  Протокол: VLESS + Reality (TCP)"
    echo "║  SNI:      ${domain}"
    echo "║  PublicKey: ${reality_public_key}"
    echo "║  ShortID:  ${reality_short_id}"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  Утилиты:                                                    ║"
    echo "║  xray-log warning|info|debug|none  — уровень логов           ║"
    echo "║  Логи Xray: /var/log/xray-cascade/                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
}

###############################################################################
# MODE: SERVER 2
###############################################################################
run_server2() {
    require_root

    section "Установка Сервера 2 (relay)"

    local server1_ip=""
    local listen_port
    local uuid
    local xhttp_path

    read -rp "$(question 'IP Сервера 1 (для UFW): ')" server1_ip
    listen_port=$(random_port)
    uuid=$(generate_uuid)
    xhttp_path="/$(generate_path)"

    echo
    info "Будет использовано:"
    info "  Порт:  $listen_port"
    info "  UUID:  $uuid"
    info "  Путь:  $xhttp_path"
    echo
    read -rp "$(question 'Продолжить? [Y/n]: ')" confirm
    [[ "${confirm,,}" == "n" ]] && exit 0

    install_dependencies
    install_xray
    setup_xray_service
    setup_bbr
    setup_fail2ban
    setup_auto_updates
    setup_logrotate
    setup_log_switcher

    mkdir -p "$SCRIPT_DIR"
    "$SCRIPT_DIR/update_geo.sh" 2>/dev/null || \
        { info "Устанавливаем geo файлы..."; install_geo_files; }

    configure_server2 "$listen_port" "$uuid" "$xhttp_path"
    setup_firewall "server2" "$listen_port" "$server1_ip"

    systemctl restart xray
    sleep 2
    verify_server2 "$listen_port"

    echo ""
    echo "╔══════════════════════════════════════════════════════════════╗"
    echo "║         ДАННЫЕ ДЛЯ ВВОДА НА СЕРВЕРЕ 1 — СОХРАНИ!           ║"
    echo "╠══════════════════════════════════════════════════════════════╣"
    echo "║  IP Сервера 2: $(get_public_ip)"
    echo "║  Порт:         ${listen_port}"
    echo "║  UUID:         ${uuid}"
    echo "║  Путь:         ${xhttp_path}"
    echo "╚══════════════════════════════════════════════════════════════╝"
}

###############################################################################
# MODE: SERVER 1
###############################################################################
run_server1() {
    require_root

    section "Установка Сервера 1 (entry + cascade)"

    local server1_ip
    server1_ip=$(get_public_ip)

    # Сбор данных
    local domain email cf_token=""
    local server2_ip server2_port server2_uuid server2_path
    local proxy_ip="" proxy_port="1080"

    echo
    read -rp "$(question 'Домен (A-запись → этот сервер): ')" domain
    read -rp "$(question 'Email для Let'\''s Encrypt: ')" email

    echo
    info "Cloudflare API токен — опционально (для wildcard сертификата)"
    info "Если не нужен — нажмите Enter"
    read -rp "$(question 'CF API токен: ')" cf_token

    echo
    info "Данные Сервера 2 (получены при его установке):"
    read -rp "$(question 'IP Сервера 2: ')" server2_ip
    read -rp "$(question 'Порт Сервера 2: ')" server2_port
    read -rp "$(question 'UUID Сервера 2: ')" server2_uuid
    read -rp "$(question 'Путь Сервера 2: ')" server2_path

    echo
    read -rp "$(question 'Использовать SOCKS5 прокси для установки? [y/N]: ')" use_proxy
    if [[ "${use_proxy,,}" == "y" ]]; then
        read -rp "$(question 'IP прокси (Сервер 2): ')" proxy_ip
        read -rp "$(question 'Порт прокси [1080]: ')" proxy_port
        proxy_port="${proxy_port:-1080}"
    fi

    echo
    info "Параметры установки:"
    info "  Сервер 1 IP:  $server1_ip"
    info "  Домен:        $domain"
    info "  Email:        $email"
    info "  Сервер 2:     $server2_ip:$server2_port"
    echo
    read -rp "$(question 'Продолжить? [Y/n]: ')" confirm
    [[ "${confirm,,}" == "n" ]] && exit 0

    # Проверка DNS
    check_dns "$domain" "$server1_ip" || warning "DNS ещё не применился, продолжаем..."

    # Установка
    install_dependencies

    if [[ -n "$proxy_ip" ]]; then
        setup_proxychains "$proxy_ip" "$proxy_port"
    fi

    install_xray
    setup_xray_service
    install_nginx
    setup_bbr
    setup_fail2ban
    setup_auto_updates
    setup_logrotate
    setup_log_switcher

    mkdir -p "$SCRIPT_DIR"
    install_geo_files

    # Генерация параметров
    local client_uuid xhttp_path reality_port
    client_uuid=$(generate_uuid)
    xhttp_path="/$(generate_path)"
    reality_port=$(random_port)

    # Генерация ключей Reality
    local key_pair reality_private_key reality_public_key
    key_pair=$("$XRAY_BIN" x25519 2>/dev/null)
    reality_private_key=$(echo "$key_pair" | grep "PrivateKey:" | awk '{print $2}')
    reality_public_key=$(echo "$key_pair" | grep "PublicKey)" | awk '{print $NF}')
    local reality_short_id
    reality_short_id=$(openssl rand -hex 2)
    local reality_uuid
    reality_uuid=$(generate_uuid)

    # Сертификат
    issue_certificate "$domain" "$email" "$cf_token"

    # Конфиги
    configure_server1_xray \
        "$client_uuid" "$xhttp_path" \
        "$server2_ip" "$server2_port" "$server2_uuid" "$server2_path" \
        "$reality_port" "$reality_private_key" "$reality_public_key" \
        "$reality_short_id" "$domain"

    configure_server1_nginx "$domain" "$xhttp_path"

    setup_firewall "server1" "$reality_port"

    systemctl restart xray
    sleep 3

    verify_server1 "$domain" "$xhttp_path" "$reality_port"

    print_client_config \
        "$domain" "$xhttp_path" "$client_uuid" \
        "$reality_port" "$reality_uuid" \
        "$reality_public_key" "$reality_short_id" \
        "$server1_ip"
}

###############################################################################
# SHOW HELP
###############################################################################
show_help() {
    echo "Использование: $0 --mode [server1|server2]"
    echo
    echo "  --mode server1   Установка Сервера 1 (entry + Nginx + каскад)"
    echo "  --mode server2   Установка Сервера 2 (relay)"
    echo
    echo "Запускать сначала на Сервере 2, затем на Сервере 1."
}

###############################################################################
# MAIN
###############################################################################
case "${1:-}" in
    --mode)
        case "${2:-}" in
            server1) run_server1 ;;
            server2) run_server2 ;;
            *) show_help ;;
        esac
        ;;
    -h|--help|"") show_help ;;
    *) show_help ;;
esac
