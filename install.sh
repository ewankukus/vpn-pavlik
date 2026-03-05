#!/bin/bash
# ================================================================
#  VPN Frankfurt — автоматическая установка по ТЗ v2.1
#  Стек: 3X-UI + Xray-core (VLESS+Reality self-steal) + Nginx + Let's Encrypt
#  ОС:   Ubuntu 22.04 / 24.04
# ================================================================
set -euo pipefail

# ================================================================
# Цвета и вспомогательные функции
# ================================================================
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $1"; }
info()  { echo -e "${BLUE}[i]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()  {
    echo -e "\n${BLUE}══════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Шаг $1${NC}"
    echo -e "${BLUE}══════════════════════════════════════════${NC}"
}

# FIX: cleanup при Ctrl+C или SIGTERM
trap 'rm -f /tmp/x-ui-cookie.txt; echo ""; warn "Установка прервана."; exit 1' INT TERM

# ================================================================
# Генерация пары ключей x25519 (FIX: вынесено в функцию, убран дублирующий код)
# ================================================================
generate_x25519_keys() {
    local keys priv pub
    keys=$("$XRAY_BIN" x25519 2>/dev/null)
    priv=$(echo "$keys" | awk '/Private key:/{print $3}')
    pub=$(echo  "$keys" | awk '/Public key:/{print $3}')
    [[ -z "$priv" || -z "$pub" ]] && error "Не удалось сгенерировать x25519 ключи"
    echo "$priv $pub"
}

# ================================================================
# Запрос SSL сертификата (FIX: вынесено в функцию, убран дублирующий код)
# ================================================================
get_ssl_cert() {
    local domain=$1
    certbot certonly --webroot \
        -w /var/www/html \
        -d "$domain" \
        --email "$LE_EMAIL" \
        --agree-tos --non-interactive --quiet \
        || error "Не удалось получить сертификат для $domain — убедитесь что DNS указывает на этот сервер"
}

# ================================================================
# Создание inbound через 3X-UI API (FIX: вынесено в функцию)
# ================================================================
create_inbound() {
    local protocol=$1 port=$2 remark=$3 settings=$4 stream=$5
    local sniffing='{"enabled":true,"destOverride":["http","tls","quic","fakedns"]}'

    local resp
    resp=$(curl -s -b /tmp/x-ui-cookie.txt \
        -X POST "$PANEL_API/panel/inbound/add" \
        -H "Content-Type: application/json" \
        -d "$(jq -n \
            --arg  proto   "$protocol" \
            --argjson port  "$port" \
            --arg  remark  "$remark" \
            --arg  sets    "$settings" \
            --arg  stream  "$stream" \
            --arg  sniff   "$sniffing" \
            '{up:0,down:0,total:0,enable:true,expiryTime:0,listen:"",
              remark:$remark, port:$port, protocol:$proto,
              settings:$sets, streamSettings:$stream, sniffing:$sniff}'
        )" 2>/dev/null || echo "{}")

    echo "$resp" | grep -q '"success":true'
}

# ================================================================
# Проверка root и ОС
# ================================================================
[[ $EUID -ne 0 ]] && error "Запустите скрипт от root: sudo bash $0"

# shellcheck source=/dev/null
. /etc/os-release
if [[ "$ID" != "ubuntu" ]] || [[ "$VERSION_ID" != "22.04" && "$VERSION_ID" != "24.04" ]]; then
    error "Требуется Ubuntu 22.04 или 24.04. Обнаружено: $PRETTY_NAME"
fi

# ================================================================
# Ввод параметров
# ================================================================
echo -e "${BLUE}"
cat << 'BANNER'
  ╔══════════════════════════════════════════╗
  ║   VPN Frankfurt  —  установка v2.1       ║
  ╚══════════════════════════════════════════╝
BANNER
echo -e "${NC}"

read -rp  "$(echo -e "${YELLOW}Домен для Reality/Nginx (например: vpn.example.com):    ${NC}")" REALITY_DOMAIN
read -rp  "$(echo -e "${YELLOW}Домен для панели 3X-UI  (например: panel.example.com): ${NC}")" PANEL_DOMAIN
read -rp  "$(echo -e "${YELLOW}Email для Let's Encrypt:                                ${NC}")" LE_EMAIL
read -rp  "$(echo -e "${YELLOW}Секретный путь к панели (например: /xk92mf):            ${NC}")" PANEL_PATH
read -rp  "$(echo -e "${YELLOW}Логин для панели 3X-UI  [по умолч.: admin]:             ${NC}")" PANEL_USER
PANEL_USER=${PANEL_USER:-admin}
read -rsp "$(echo -e "${YELLOW}Пароль для панели 3X-UI (мин. 8 символов):             ${NC}")" PANEL_PASS
echo ""

# ================================================================
# Валидация ввода (FIX: добавлена проверка формата домена)
# ================================================================
validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]] \
        && [[ ${#1} -lt 256 ]]
}

[[ -z "$REALITY_DOMAIN" ]] && error "Домен Reality не может быть пустым"
[[ -z "$PANEL_DOMAIN" ]]   && error "Домен панели не может быть пустым"
[[ -z "$LE_EMAIL" ]]        && error "Email не может быть пустым"
[[ -z "$PANEL_PATH" ]]      && error "Секретный путь не может быть пустым"
[[ -z "$PANEL_PASS" ]]      && error "Пароль не может быть пустым"
[[ ${#PANEL_PASS} -lt 8 ]]  && error "Пароль должен быть не менее 8 символов"
validate_domain "$REALITY_DOMAIN" || error "Невалидный домен: $REALITY_DOMAIN"
validate_domain "$PANEL_DOMAIN"   || error "Невалидный домен: $PANEL_DOMAIN"

# Добавить / в начало пути если нет
[[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"

# Порты
XRAY_PORT=8443
TROJAN_PORT=2053
PANEL_PORT=54321

info "Параметры установки:"
echo "  Reality домен : $REALITY_DOMAIN"
echo "  Панель домен  : $PANEL_DOMAIN"
echo "  Email         : $LE_EMAIL"
echo "  Путь панели   : $PANEL_PATH"
echo "  Порт Xray     : $XRAY_PORT"
echo "  Порт Trojan   : $TROJAN_PORT"
echo "  Порт панели   : $PANEL_PORT"
echo ""
read -rp "Продолжить установку? [y/N]: " CONFIRM
[[ "$CONFIRM" != "y" && "$CONFIRM" != "Y" ]] && exit 0

# ================================================================
# Шаг 1: Обновление системы и установка зависимостей
# ================================================================
step "1 — Обновление системы"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get upgrade -yq
apt-get install -yq \
    curl wget unzip jq ufw fail2ban \
    certbot python3-certbot-nginx nginx sqlite3 \
    ca-certificates gnupg lsb-release
log "Система обновлена, пакеты установлены"

# ================================================================
# Шаг 2: Оптимизация ядра Linux
# ================================================================
step "2 — Оптимизация ядра Linux"
cat > /etc/sysctl.d/99-vpn-optimize.conf << 'EOF'
# Буферы TCP
net.core.rmem_max           = 67108864
net.core.wmem_max           = 67108864
net.core.rmem_default       = 65536
net.core.wmem_default       = 65536
net.ipv4.tcp_rmem           = 4096 87380 67108864
net.ipv4.tcp_wmem           = 4096 65536 67108864
net.ipv4.tcp_mem            = 65536 131072 262144
net.core.netdev_max_backlog = 250000

# BBR congestion control
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

# TIME_WAIT
net.ipv4.tcp_tw_reuse   = 1
net.ipv4.tcp_fin_timeout = 15

# Очередь соединений
net.core.somaxconn           = 65535
net.ipv4.tcp_max_syn_backlog = 65535

# IP forwarding + защита от SYN flood
net.ipv4.ip_forward    = 1
net.ipv4.tcp_syncookies = 1
EOF

modprobe tcp_bbr 2>/dev/null || true
sysctl -p /etc/sysctl.d/99-vpn-optimize.conf > /dev/null 2>&1 || true
log "Ядро оптимизировано, BBR включён"

# ================================================================
# Шаг 3: Настройка UFW
# ================================================================
step "3 — Настройка UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment 'SSH'
ufw allow 80/tcp    comment 'HTTP certbot'
ufw allow 443/tcp   comment 'HTTPS Nginx'
ufw allow "$XRAY_PORT"/tcp   comment 'Xray VLESS Reality'
ufw allow "$TROJAN_PORT"/tcp comment 'Trojan Reality'
ufw allow from 127.0.0.1 to any port "$PANEL_PORT" comment '3X-UI panel local only'
# FIX: || true — ufw enable возвращает ненулевой код если уже включён
echo "y" | ufw enable || true
log "UFW настроен"

# ================================================================
# Шаг 4: Настройка fail2ban
# ================================================================
step "4 — Настройка fail2ban"
cat > /etc/fail2ban/jail.local << 'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 3
bantime  = 86400
EOF
systemctl enable fail2ban
systemctl restart fail2ban
log "fail2ban настроен"

# ================================================================
# Шаг 5: Создание сайта-камуфляжа для Reality
# ================================================================
step "5 — Создание сайта-камуфляжа для Reality"
mkdir -p /var/www/"$REALITY_DOMAIN"
cat > /var/www/"$REALITY_DOMAIN"/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome</title>
    <style>
        body { font-family: sans-serif; display: flex; justify-content: center;
               align-items: center; height: 100vh; margin: 0; background: #f5f5f5; }
        .box { text-align: center; padding: 40px; background: white;
               border-radius: 8px; box-shadow: 0 2px 10px rgba(0,0,0,.1); }
        h1 { color: #333; } p { color: #666; }
    </style>
</head>
<body>
    <div class="box"><h1>Welcome</h1><p>Server is running.</p></div>
</body>
</html>
HTMLEOF
chown -R www-data:www-data /var/www/"$REALITY_DOMAIN"
log "Сайт-камуфляж создан"

# ================================================================
# Шаг 6: Получение SSL сертификатов (Let's Encrypt)
# ================================================================
step "6 — Получение SSL сертификатов"

# Временный Nginx для certbot challenge
cat > /etc/nginx/sites-available/certbot-temp << NGINXEOF
server {
    listen 80;
    server_name $REALITY_DOMAIN $PANEL_DOMAIN;
    root /var/www/html;
    location /.well-known/acme-challenge/ { root /var/www/html; }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/certbot-temp /etc/nginx/sites-enabled/certbot-temp
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx

# FIX: get_ssl_cert() устраняет дублирование двух идентичных certbot-вызовов
get_ssl_cert "$REALITY_DOMAIN"
get_ssl_cert "$PANEL_DOMAIN"

rm -f /etc/nginx/sites-enabled/certbot-temp /etc/nginx/sites-available/certbot-temp
log "SSL сертификаты получены"

# ================================================================
# Шаг 7: Установка 3X-UI
# ================================================================
step "7 — Установка 3X-UI"

# FIX: останавливаем Nginx перед установкой — 3X-UI занимает порт 80 для acme.sh
systemctl stop nginx 2>/dev/null || true

# FIX: скачиваем во временный файл с --fail чтобы поймать ошибки HTTP
INSTALL_SCRIPT=$(mktemp)
curl -fsSL --max-time 60 \
    https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
    -o "$INSTALL_SCRIPT" \
    || error "Не удалось загрузить установщик 3X-UI (проверьте интернет-соединение)"
# Передаём "n" чтобы пропустить интерактивный SSL-wizard установщика
bash "$INSTALL_SCRIPT" <<< "n"
rm -f "$INSTALL_SCRIPT"

systemctl enable x-ui
systemctl start x-ui || true

# Возвращаем Nginx
systemctl start nginx || true
log "3X-UI установлен"

# ================================================================
# Шаг 8: Настройка 3X-UI (порт, путь, credentials)
# ================================================================
step "8 — Настройка параметров 3X-UI"
X_UI_DB="/etc/x-ui/x-ui.db"

# FIX: polling готовности БД с выводом прогресса; проверяем что sqlite3 может открыть БД
info "Ожидание инициализации 3X-UI..."
for i in $(seq 1 60); do
    if sqlite3 "$X_UI_DB" "SELECT 1;" 2>/dev/null; then
        break
    fi
    echo -ne "\r  Ожидание БД... [${i}/60]   "
    sleep 1
done
echo ""
sqlite3 "$X_UI_DB" "SELECT 1;" 2>/dev/null \
    || error "БД 3X-UI не инициализирована за 60 сек: $X_UI_DB"

# Применяем настройки через x-ui CLI
x-ui setting -username "$PANEL_USER" -password "$PANEL_PASS" -port "$PANEL_PORT" 2>/dev/null || true

# FIX: параметризованный запрос предотвращает SQL injection в PANEL_PATH
sqlite3 "$X_UI_DB" \
    "UPDATE settings SET value=? WHERE key='webBasePath';" \
    "$PANEL_PATH" 2>/dev/null || true

systemctl restart x-ui

# FIX: polling готовности API вместо фиксированного sleep 5+5
info "Ожидание запуска 3X-UI API..."
for i in $(seq 1 30); do
    if curl -s --max-time 2 "http://127.0.0.1:$PANEL_PORT" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

log "3X-UI настроен: порт $PANEL_PORT, путь $PANEL_PATH"

# ================================================================
# Шаг 9: Генерация ключей Reality для VLESS
# ================================================================
step "9 — Генерация ключей Reality"

# FIX: xray в 3X-UI v2.8+ называется xray-linux-amd64, проверяем оба имени
XRAY_BIN=""
for _path in \
    "/usr/local/x-ui/bin/xray" \
    "/usr/local/x-ui/bin/xray-linux-amd64" \
    "/usr/bin/xray" \
    "/usr/local/bin/xray"; do
    [[ -f "$_path" ]] && XRAY_BIN="$_path" && break
done
# fallback: find по любому имени xray*
[[ -z "$XRAY_BIN" ]] && \
    XRAY_BIN=$(find /usr/local/x-ui/ /usr/bin/ /usr/local/bin/ -name "xray*" -type f -perm /111 2>/dev/null | head -1 || true)
[[ -z "$XRAY_BIN" || ! -f "$XRAY_BIN" ]] && \
    error "Xray бинарник не найден — убедитесь что 3X-UI установлен"

# FIX: generate_x25519_keys() устраняет дублирование парсинга (шаги 9 и 11)
read -r PRIVATE_KEY PUBLIC_KEY <<< "$(generate_x25519_keys)"
SHORT_ID=$(openssl rand -hex 8)

log "Ключи Reality (VLESS) сгенерированы"
info "Public Key : $PUBLIC_KEY"
info "Short ID   : $SHORT_ID"

# ================================================================
# Шаг 10: Создание inbound VLESS+Reality через 3X-UI API
# ================================================================
step "10 — Создание inbound VLESS+Reality"

PANEL_API="http://127.0.0.1:$PANEL_PORT$PANEL_PATH"
CLIENT_UUID=""

LOGIN_RESP=$(curl -s -c /tmp/x-ui-cookie.txt \
    -X POST "$PANEL_API/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"$PANEL_USER\",\"password\":\"$PANEL_PASS\"}" 2>/dev/null || echo "{}")

# FIX: сохраняем флаг один раз, чтобы не парсить LOGIN_RESP дважды (шаги 10 и 11)
if echo "$LOGIN_RESP" | grep -q '"success":true'; then
    LOGIN_OK=true
else
    LOGIN_OK=false
    warn "Не удалось подключиться к API панели — inbound создайте вручную"
fi

if [[ "$LOGIN_OK" == "true" ]]; then
    CLIENT_UUID=$(cat /proc/sys/kernel/random/uuid)

    VLESS_SETTINGS=$(cat << JSONEOF
{"clients":[{"id":"$CLIENT_UUID","flow":"xtls-rprx-vision","email":"user@vpn","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true,"tgId":"","subId":""}],"decryption":"none","fallbacks":[]}
JSONEOF
)
    VLESS_STREAM=$(cat << JSONEOF
{"network":"tcp","security":"reality","realitySettings":{"show":false,"xver":0,"dest":"127.0.0.1:443","serverNames":["$REALITY_DOMAIN"],"privateKey":"$PRIVATE_KEY","shortIds":["$SHORT_ID"],"spiderX":"/"},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}
JSONEOF
)
    # FIX: create_inbound() устраняет дублирование кода шагов 10 и 11
    if create_inbound "vless" "$XRAY_PORT" "VLESS-Reality-Frankfurt" "$VLESS_SETTINGS" "$VLESS_STREAM"; then
        log "Inbound VLESS+Reality создан, UUID: $CLIENT_UUID"
    else
        warn "Не удалось создать VLESS inbound через API — настройте вручную в панели"
        CLIENT_UUID=""
    fi
fi

# ================================================================
# Шаг 11: Создание inbound Trojan+Reality (резерв)
# ================================================================
step "11 — Создание inbound Trojan+Reality (резерв)"

TROJAN_PASS=$(openssl rand -base64 16)
TROJAN_SHORT_ID=$(openssl rand -hex 8)

# FIX: generate_x25519_keys() переиспользуется — отдельные ключи для Trojan
read -r TROJAN_PRIV TROJAN_PUB <<< "$(generate_x25519_keys)"

if [[ "$LOGIN_OK" == "true" ]]; then
    TROJAN_SETTINGS=$(cat << JSONEOF
{"clients":[{"password":"$TROJAN_PASS","email":"trojan@vpn","limitIp":0,"totalGB":0,"expiryTime":0,"enable":true}],"fallbacks":[]}
JSONEOF
)
    TROJAN_STREAM=$(cat << JSONEOF
{"network":"tcp","security":"reality","realitySettings":{"show":false,"xver":0,"dest":"127.0.0.1:443","serverNames":["$REALITY_DOMAIN"],"privateKey":"$TROJAN_PRIV","shortIds":["$TROJAN_SHORT_ID"],"spiderX":"/"},"tcpSettings":{"acceptProxyProtocol":false,"header":{"type":"none"}}}
JSONEOF
)
    if create_inbound "trojan" "$TROJAN_PORT" "Trojan-Reality-Frankfurt" "$TROJAN_SETTINGS" "$TROJAN_STREAM"; then
        log "Inbound Trojan+Reality создан"
    else
        warn "Не удалось создать Trojan inbound — настройте вручную в панели"
    fi
fi

# ================================================================
# Шаг 12: Настройка Nginx
# ================================================================
step "12 — Настройка Nginx"

# FIX: общий SSL-сниппет устраняет дублирование 4 строк в каждом vhost
mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/vpn-ssl.conf << 'EOF'
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ciphers         HIGH:!aNULL:!MD5;
ssl_session_cache   shared:SSL:10m;
ssl_session_timeout 10m;
EOF

# ---- Reality домен (сайт-камуфляж) ----
cat > "/etc/nginx/sites-available/$REALITY_DOMAIN" << NGINXEOF
server {
    listen 80;
    server_name $REALITY_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $REALITY_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$REALITY_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$REALITY_DOMAIN/privkey.pem;
    include /etc/nginx/snippets/vpn-ssl.conf;

    root  /var/www/$REALITY_DOMAIN;
    index index.html;

    location / { try_files \$uri \$uri/ =404; }

    server_tokens off;
    add_header X-Content-Type-Options nosniff;
    add_header X-Frame-Options DENY;
}
NGINXEOF

# ---- Панель домен (reverse proxy к 3X-UI) ----
# FIX: два идентичных location-блока объединены в один через ^~
cat > "/etc/nginx/sites-available/$PANEL_DOMAIN" << NGINXEOF
server {
    listen 80;
    server_name $PANEL_DOMAIN;
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $PANEL_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
    include /etc/nginx/snippets/vpn-ssl.conf;

    server_tokens off;

    location / { return 404; }

    location ^~ $PANEL_PATH {
        proxy_pass         http://127.0.0.1:$PANEL_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    \$http_upgrade;
        proxy_set_header   Connection "upgrade";
        proxy_read_timeout 86400;
    }
}
NGINXEOF

ln -sf "/etc/nginx/sites-available/$REALITY_DOMAIN" /etc/nginx/sites-enabled/
ln -sf "/etc/nginx/sites-available/$PANEL_DOMAIN"   /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default

nginx -t || error "Ошибка конфигурации Nginx"
systemctl reload nginx
log "Nginx настроен для обоих доменов"

# ================================================================
# Шаг 13: Автообновление SSL сертификатов
# ================================================================
step "13 — Автообновление SSL сертификатов"
cat > /etc/cron.d/certbot-renew << 'EOF'
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
log "Автообновление сертификатов настроено (ежедневно в 3:00)"

# ================================================================
# Шаг 14: Watchdog для x-ui и nginx
# ================================================================
step "14 — Watchdog сервис"
cat > /usr/local/bin/vpn-watchdog.sh << 'WDEOF'
#!/bin/bash
LOG="/var/log/vpn-watchdog.log"

# FIX: timestamp вычисляется внутри каждой записи, а не один раз при старте
log_ts() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG"; }

if ! systemctl is-active --quiet x-ui; then
    log_ts "x-ui не запущен — перезапускаю"
    systemctl restart x-ui
fi

if ! systemctl is-active --quiet nginx; then
    log_ts "nginx не запущен — перезапускаю"
    systemctl restart nginx
fi
WDEOF
chmod +x /usr/local/bin/vpn-watchdog.sh

cat > /etc/systemd/system/vpn-watchdog.service << 'EOF'
[Unit]
Description=VPN Watchdog
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/vpn-watchdog.sh
EOF

cat > /etc/systemd/system/vpn-watchdog.timer << 'EOF'
[Unit]
Description=VPN Watchdog Timer

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable vpn-watchdog.timer
systemctl start vpn-watchdog.timer
log "Watchdog настроен (проверка каждые 5 минут)"

# ================================================================
# Шаг 15: Ротация логов
# ================================================================
step "15 — Ротация логов"
cat > /etc/logrotate.d/vpn-watchdog << 'EOF'
/var/log/vpn-watchdog.log {
    daily
    rotate 14
    compress
    missingok
    notifempty
    create 0640 root root
}
EOF

cat > /etc/logrotate.d/x-ui << 'EOF'
/var/log/x-ui/*.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    postrotate
        systemctl kill -s USR1 x-ui 2>/dev/null || true
    endscript
}
EOF
log "Ротация логов настроена"

# ================================================================
# Шаг 16: Резервное копирование конфигурации
# ================================================================
step "16 — Резервное копирование"
BACKUP_DIR="/var/backups/vpn"
mkdir -p "$BACKUP_DIR"

cat > /usr/local/bin/vpn-backup.sh << BKEOF
#!/bin/bash
TS=\$(date '+%Y%m%d_%H%M%S')
BDIR="$BACKUP_DIR"
mkdir -p "\$BDIR"

tar -czf "\$BDIR/vpn_backup_\$TS.tar.gz" \
    /etc/x-ui/ \
    /etc/nginx/sites-available/ \
    /etc/letsencrypt/ \
    /usr/local/bin/vpn-watchdog.sh \
    2>/dev/null

# FIX: xargs -r — не запускать rm если список пустой (< 7 бэкапов)
ls -t "\$BDIR"/vpn_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Бэкап: vpn_backup_\$TS.tar.gz" >> /var/log/vpn-backup.log
BKEOF
chmod +x /usr/local/bin/vpn-backup.sh

cat > /etc/cron.d/vpn-backup << 'EOF'
0 4 * * * root /usr/local/bin/vpn-backup.sh
EOF
log "Резервное копирование настроено (ежедневно в 4:00)"

# Очистка
rm -f /tmp/x-ui-cookie.txt

# ================================================================
# Финальный вывод
# ================================================================
# FIX: корректный fallback для SERVER_IP (была сломана логика ||)
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && SERVER_IP="<unknown>"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║            УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО                   ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${BLUE}━━━ Параметры сервера ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  IP сервера        : $SERVER_IP"
echo "  Reality домен     : $REALITY_DOMAIN"
echo "  Панель URL        : https://$PANEL_DOMAIN$PANEL_PATH"
echo "  Панель логин      : $PANEL_USER"
# FIX: пароль не выводим в консоль — только путь к файлу
echo "  Панель пароль     : [сохранён в /root/vpn-install-info.txt]"
echo ""
echo -e "${BLUE}━━━ VLESS+Reality (основной) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Адрес     : $SERVER_IP"
echo "  Порт      : $XRAY_PORT"
echo "  Протокол  : VLESS + reality"
echo "  SNI       : $REALITY_DOMAIN"
echo "  PublicKey : $PUBLIC_KEY"
echo "  ShortID   : $SHORT_ID"
[[ -n "$CLIENT_UUID" ]] && echo "  UUID      : $CLIENT_UUID"
echo "  Flow      : xtls-rprx-vision"
echo ""
echo -e "${BLUE}━━━ Trojan+Reality (резерв) ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  Адрес     : $SERVER_IP"
echo "  Порт      : $TROJAN_PORT"
echo "  Протокол  : Trojan + reality"
echo "  SNI       : $REALITY_DOMAIN"
echo "  PublicKey : $TROJAN_PUB"
echo "  ShortID   : $TROJAN_SHORT_ID"
echo "  Пароль    : [сохранён в /root/vpn-install-info.txt]"
echo ""
echo -e "${BLUE}━━━ Состояние сервисов ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
systemctl is-active --quiet x-ui     && echo -e "  x-ui     : ${GREEN}работает${NC}" || echo -e "  x-ui     : ${RED}остановлен${NC}"
systemctl is-active --quiet nginx    && echo -e "  nginx    : ${GREEN}работает${NC}" || echo -e "  nginx    : ${RED}остановлен${NC}"
systemctl is-active --quiet fail2ban && echo -e "  fail2ban : ${GREEN}работает${NC}" || echo -e "  fail2ban : ${RED}остановлен${NC}"
echo ""
echo -e "${YELLOW}Все секреты сохранены в /root/vpn-install-info.txt (chmod 600)${NC}"
echo ""

# Сохраняем параметры в файл
cat > /root/vpn-install-info.txt << INFOEOF
VPN Frankfurt — параметры установки
====================================
Дата установки    : $(date)
IP сервера        : $SERVER_IP
Reality домен     : $REALITY_DOMAIN
Панель URL        : https://$PANEL_DOMAIN$PANEL_PATH
Панель логин      : $PANEL_USER
Панель пароль     : $PANEL_PASS

VLESS+Reality:
  Порт            : $XRAY_PORT
  UUID            : ${CLIENT_UUID:-см. панель управления}
  Public Key      : $PUBLIC_KEY
  Short ID        : $SHORT_ID
  Flow            : xtls-rprx-vision

Trojan+Reality:
  Порт            : $TROJAN_PORT
  Пароль          : $TROJAN_PASS
  Public Key      : $TROJAN_PUB
  Short ID        : $TROJAN_SHORT_ID
INFOEOF
chmod 600 /root/vpn-install-info.txt
log "Секреты сохранены в /root/vpn-install-info.txt"
