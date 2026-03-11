#!/bin/bash
# ================================================================
#  VPN TOPGUN — автоматическая установка
#  Стек: 3X-UI + Xray-core (VLESS+Reality self-steal) + Nginx + Let's Encrypt
#  ОС:   Ubuntu 22.04 / 24.04
# ================================================================
set -euo pipefail

# ================================================================
# Цвета и вспомогательные функции
# ================================================================
RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()   { echo "${GREEN}[✓]${NC} $1"; }
info()  { echo "${BLUE}[i]${NC} $1"; }
warn()  { echo "${YELLOW}[!]${NC} $1"; }
error() { echo "${RED}[✗]${NC} $1"; exit 1; }
step()  {
    echo ""
    echo "${BLUE}══════════════════════════════════════════${NC}"
    echo "${BLUE}  Шаг $1${NC}"
    echo "${BLUE}══════════════════════════════════════════${NC}"
}

INSTALL_SCRIPT=""
trap 'rm -f "$INSTALL_SCRIPT"' EXIT
trap 'echo ""; warn "Установка прервана."; exit 1' INT TERM

# ================================================================
# Получение SSL сертификата через certbot
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
echo "${BLUE}"
cat << 'BANNER'
  ╔══════════════════════════════════════════╗
  ║          VPN TOPGUN — установка          ║
  ╚══════════════════════════════════════════╝
BANNER
echo "${NC}"

read -rp  "${YELLOW}Домен для Reality/Nginx (например: domain1.ru):         ${NC}" REALITY_DOMAIN
read -rp  "${YELLOW}Email для Let's Encrypt:                                ${NC}" LE_EMAIL
read -rp  "${YELLOW}Логин для панели 3X-UI  [по умолч.: admin]:             ${NC}" PANEL_USER
PANEL_USER=${PANEL_USER:-admin}
read -rsp "${YELLOW}Пароль для панели 3X-UI (мин. 8 символов):             ${NC}" PANEL_PASS
echo ""
echo ""
echo "${YELLOW}Режим панели:${NC}"
echo "  1) Domain — панель за Nginx (https://domain2.ru), нужен отдельный домен"
echo "  2) IP     — панель напрямую (https://IP:порт/путь), домен не нужен"
read -rp "${YELLOW}Выберите режим [1/2]:                                   ${NC}" MODE_INPUT
echo ""

if [[ "$MODE_INPUT" == "1" ]]; then
    PANEL_MODE="domain"
    read -rp "${YELLOW}Домен для панели 3X-UI  (например: domain2.ru):         ${NC}" PANEL_DOMAIN
    PANEL_PATH="/"
elif [[ "$MODE_INPUT" == "2" ]]; then
    PANEL_MODE="ip"
    PANEL_DOMAIN=""
    read -rp "${YELLOW}Секретный путь к панели (например: /xk92mf):            ${NC}" PANEL_PATH
else
    error "Выберите 1 или 2"
fi

# ================================================================
# Валидация ввода
# ================================================================
validate_domain() {
    [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)+$ ]] \
        && [[ ${#1} -lt 256 ]]
}

[[ -z "$REALITY_DOMAIN" ]] && error "Домен Reality не может быть пустым"
[[ -z "$LE_EMAIL" ]]        && error "Email не может быть пустым"
[[ -z "$PANEL_PASS" ]]      && error "Пароль не может быть пустым"
[[ ${#PANEL_PASS} -lt 8 ]]  && error "Пароль должен быть не менее 8 символов"
validate_domain "$REALITY_DOMAIN" || error "Невалидный домен: $REALITY_DOMAIN"
[[ "$PANEL_USER" =~ ^[a-zA-Z0-9_-]+$ ]] || error "Логин может содержать только буквы, цифры, _ и -"
[[ "$LE_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]] || error "Невалидный email: $LE_EMAIL"

if [[ "$PANEL_MODE" == "domain" ]]; then
    [[ -z "$PANEL_DOMAIN" ]] && error "Домен панели не может быть пустым"
    validate_domain "$PANEL_DOMAIN" || error "Невалидный домен: $PANEL_DOMAIN"
    [[ "$PANEL_DOMAIN" == "$REALITY_DOMAIN" ]] && error "Домен панели должен отличаться от домена Reality"
else
    [[ -z "$PANEL_PATH" ]] && error "Секретный путь не может быть пустым"
    # Добавить / в начало пути если нет
    [[ "$PANEL_PATH" != /* ]] && PANEL_PATH="/$PANEL_PATH"
fi

# Порты
XRAY_PORT=443
TROJAN_PORT=2053
PANEL_NGINX_PORT=8443
PANEL_PORT=$(shuf -i 10000-65000 -n 1)
while ss -tlnH 2>/dev/null | grep -q ":${PANEL_PORT}"; do
    PANEL_PORT=$(shuf -i 10000-65000 -n 1)
done
if [[ "$PANEL_MODE" == "domain" ]] && ss -tlnH 2>/dev/null | grep -q ":${PANEL_NGINX_PORT}"; then
    error "Порт $PANEL_NGINX_PORT (панель HTTPS) уже занят. Освободите его и повторите установку."
fi

info "Параметры установки:"
echo "  Reality домен : $REALITY_DOMAIN"
if [[ "$PANEL_MODE" == "domain" ]]; then
    echo "  Панель домен  : $PANEL_DOMAIN"
else
    echo "  Режим панели  : IP (порт $PANEL_PORT)"
    echo "  Путь панели   : $PANEL_PATH"
fi
echo "  Email         : $LE_EMAIL"
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
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1
apt-get update -q
apt-get upgrade -yq
apt-get install -yq \
    curl wget unzip jq ufw fail2ban \
    certbot nginx sqlite3 \
    python3-bcrypt python3-systemd \
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
sysctl -p /etc/sysctl.d/99-vpn-optimize.conf > /dev/null 2>&1 \
    || warn "Некоторые параметры ядра не применились (проверьте: sysctl -p /etc/sysctl.d/99-vpn-optimize.conf)"
log "Ядро оптимизировано, BBR включён"

# ================================================================
# Шаг 3: Настройка UFW
# ================================================================
step "3 — Настройка UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp             comment 'SSH'
ufw allow 80/tcp             comment 'HTTP certbot'
ufw allow 443/tcp            comment 'HTTPS / Xray VLESS Reality'
ufw allow "$TROJAN_PORT"/tcp comment 'Trojan Reality'

if [[ "$PANEL_MODE" == "domain" ]]; then
    # Панель на $PANEL_NGINX_PORT (443 занят Xray)
    ufw allow "$PANEL_NGINX_PORT"/tcp comment 'Panel domain HTTPS'
    ufw allow from 127.0.0.1 to any port "$PANEL_PORT" comment '3X-UI panel local only'
else
    # Панель доступна напрямую по IP
    ufw allow "$PANEL_PORT"/tcp comment '3X-UI panel'
fi

echo "y" | ufw enable || warn "UFW не удалось включить — проверьте наличие iptables (контейнер?)"
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
backend  = auto

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
mkdir -p /var/www/html
CERTBOT_DOMAINS="$REALITY_DOMAIN"
[[ "$PANEL_MODE" == "domain" ]] && CERTBOT_DOMAINS="$REALITY_DOMAIN $PANEL_DOMAIN"

cat > /etc/nginx/sites-available/certbot-temp << NGINXEOF
server {
    listen 80;
    listen [::]:80;
    server_name $CERTBOT_DOMAINS;
    root /var/www/html;
}
NGINXEOF

ln -sf /etc/nginx/sites-available/certbot-temp /etc/nginx/sites-enabled/certbot-temp
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx

get_ssl_cert "$REALITY_DOMAIN"
[[ "$PANEL_MODE" == "domain" ]] && get_ssl_cert "$PANEL_DOMAIN"

rm -f /etc/nginx/sites-enabled/certbot-temp /etc/nginx/sites-available/certbot-temp
log "SSL сертификаты получены"

# ================================================================
# Шаг 7: Установка 3X-UI
# ================================================================
step "7 — Установка 3X-UI"

# 3X-UI installer использует порт 80 для acme.sh — освобождаем его
systemctl stop nginx 2>/dev/null || true

INSTALL_SCRIPT=$(mktemp)
curl -fsSL --max-time 60 \
    https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh \
    -o "$INSTALL_SCRIPT" \
    || error "Не удалось загрузить установщик 3X-UI (проверьте интернет-соединение)"
bash "$INSTALL_SCRIPT" <<< "n" \
    || error "Установщик 3X-UI завершился с ошибкой — проверьте: journalctl -u x-ui"
rm -f "$INSTALL_SCRIPT"
INSTALL_SCRIPT=""

systemctl enable x-ui
systemctl start x-ui || true

systemctl start nginx || true
log "3X-UI установлен"

# ================================================================
# Шаг 8: Настройка 3X-UI (порт, путь, credentials)
# ================================================================
step "8 — Настройка параметров 3X-UI"
X_UI_DB="/etc/x-ui/x-ui.db"

# Ждём пока x-ui инициализирует БД, затем останавливаем его перед записью.
# Важно: x-ui хранит настройки в памяти и сбрасывает их в БД при остановке.
# Если писать в БД пока он работает — он перетрёт наши изменения при shutdown.
info "Ожидание инициализации 3X-UI..."
for i in {1..60}; do
    sqlite3 "$X_UI_DB" "SELECT 1;" > /dev/null 2>&1 && break
    echo -ne "\r  Ожидание БД... [${i}/60]   "
    sleep 1
done
echo ""
sqlite3 "$X_UI_DB" "SELECT 1;" > /dev/null 2>&1 \
    || error "БД 3X-UI не инициализирована за 60 сек: $X_UI_DB"

# Останавливаем x-ui — теперь БД наша, записи не будут перетёрты
systemctl stop x-ui

# Credentials: bcrypt-хеш напрямую в таблицу users
PASS_HASH=$(printf '%s' "$PANEL_PASS" | python3 -c "import bcrypt,sys; p=sys.stdin.buffer.read(); print(bcrypt.hashpw(p,bcrypt.gensalt(10)).decode())" 2>/dev/null)
if [[ -n "$PASS_HASH" ]]; then
    sqlite3 "$X_UI_DB" "DELETE FROM users; INSERT INTO users(id,username,password) VALUES(1,'$PANEL_USER','$PASS_HASH');"
else
    warn "Не удалось создать bcrypt хеш — смените пароль в панели вручную"
fi

# Порт и путь — всегда наши
sqlite3 "$X_UI_DB" "DELETE FROM settings WHERE key='webPort';     INSERT INTO settings(key,value) VALUES('webPort','$PANEL_PORT');"
sqlite3 "$X_UI_DB" "DELETE FROM settings WHERE key='webBasePath'; INSERT INTO settings(key,value) VALUES('webBasePath','$PANEL_PATH');"

# Получаем IP сервера один раз — нужен для acme.sh в обоих режимах
SERVER_IP_TMP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)

if [[ "$PANEL_MODE" == "domain" ]]; then
    # Nginx обслуживает SSL — x-ui работает plain HTTP
    sqlite3 "$X_UI_DB" "DELETE FROM settings WHERE key='webCertFile'; INSERT INTO settings(key,value) VALUES('webCertFile','');"
    sqlite3 "$X_UI_DB" "DELETE FROM settings WHERE key='webKeyFile';  INSERT INTO settings(key,value) VALUES('webKeyFile','');"
    # IP-сертификат от установщика 3X-UI нам не нужен.
    # Отключаем acme.sh задание: иначе каждые 6 дней оно падает
    # (порт 80 занят nginx) и перезапускает x-ui.
    [[ -n "$SERVER_IP_TMP" ]] && ~/.acme.sh/acme.sh --remove -d "$SERVER_IP_TMP" --ecc 2>/dev/null || true
    crontab -l 2>/dev/null | grep -v '/\.acme\.sh/acme\.sh' | crontab - 2>/dev/null || true
else
    # IP режим: x-ui обслуживает SSL сам через IP-сертификат от установщика.
    # Настраиваем acme.sh на корректное обновление: останавливаем nginx
    # перед renewal (нужен порт 80 для standalone), запускаем после.
    if [[ -n "$SERVER_IP_TMP" && -f ~/.acme.sh/acme.sh ]]; then
        ~/.acme.sh/acme.sh --install-cert -d "$SERVER_IP_TMP" \
            --pre-hook  "systemctl stop nginx" \
            --post-hook "systemctl start nginx" \
            --reloadcmd "systemctl restart x-ui" \
            --ecc 2>/dev/null || true
    fi
fi

systemctl start x-ui

# Ожидаем запуска x-ui на заданном порту
info "Ожидание запуска 3X-UI..."
for i in {1..30}; do
    curl -s --max-time 2 "http://127.0.0.1:$PANEL_PORT" >/dev/null 2>&1 && break
    sleep 1
done

systemctl is-active --quiet x-ui \
    || error "3X-UI не запустился — проверьте: journalctl -u x-ui -n 50"

if [[ "$PANEL_MODE" == "ip" ]]; then
    log "3X-UI настроен: порт $PANEL_PORT, путь $PANEL_PATH"
else
    log "3X-UI настроен: порт $PANEL_PORT"
fi

# ================================================================
# Шаг 9: Настройка Nginx
# ================================================================
step "9 — Настройка Nginx"

mkdir -p /etc/nginx/snippets
cat > /etc/nginx/snippets/vpn-ssl.conf << 'EOF'
ssl_protocols       TLSv1.2 TLSv1.3;
ssl_ciphers         HIGH:!aNULL:!MD5;
ssl_session_cache   shared:SSL:10m;
ssl_session_timeout 10m;
EOF

# ---- Reality домен — только HTTP (port 80 для certbot) ----
# Порт 443 занят Xray (VLESS+Reality), nginx на 443 не нужен.
# Xray форвардит non-Reality TLS на target (tunnel.vk.com:443).
cat > "/etc/nginx/sites-available/$REALITY_DOMAIN" << NGINXEOF
server {
    listen 80;
    server_name $REALITY_DOMAIN;
    root /var/www/$REALITY_DOMAIN;
    index index.html;

    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { try_files \$uri \$uri/ =404; }

    server_tokens off;
}
NGINXEOF

ln -sf "/etc/nginx/sites-available/$REALITY_DOMAIN" /etc/nginx/sites-enabled/

# ---- Панель домен (только в domain режиме) ----
if [[ "$PANEL_MODE" == "domain" ]]; then
    cat > "/etc/nginx/sites-available/$PANEL_DOMAIN" << NGINXEOF
server {
    listen 80;
    server_name $PANEL_DOMAIN;

    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host:${PANEL_NGINX_PORT}\$request_uri; }
}

server {
    listen ${PANEL_NGINX_PORT} ssl http2;
    server_name $PANEL_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
    include /etc/nginx/snippets/vpn-ssl.conf;

    server_tokens off;

    location / {
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

    ln -sf "/etc/nginx/sites-available/$PANEL_DOMAIN" /etc/nginx/sites-enabled/
fi

rm -f /etc/nginx/sites-enabled/default

nginx -t || error "Ошибка конфигурации Nginx"
systemctl restart nginx
log "Nginx настроен"

# ================================================================
# Шаг 10: Автообновление SSL сертификатов
# ================================================================
step "10 — Автообновление SSL сертификатов"
cat > /etc/cron.d/certbot-renew << 'EOF'
0 3 * * * root certbot renew --quiet --deploy-hook "systemctl reload nginx"
EOF
log "Автообновление сертификатов настроено (ежедневно в 3:00)"

# ================================================================
# Шаг 11: Watchdog для x-ui и nginx
# ================================================================
step "11 — Watchdog сервис"
cat > /usr/local/bin/vpn-watchdog.sh << 'WDEOF'
#!/bin/bash
LOG="/var/log/vpn-watchdog.log"

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
# Шаг 12: Ротация логов
# ================================================================
step "12 — Ротация логов"
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
# Шаг 13: Резервное копирование конфигурации
# ================================================================
step "13 — Резервное копирование"
BACKUP_DIR="/var/backups/vpn"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

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

ls -t "\$BDIR"/vpn_backup_*.tar.gz 2>/dev/null | tail -n +8 | xargs -r rm -f
echo "[\$(date '+%Y-%m-%d %H:%M:%S')] Бэкап: vpn_backup_\$TS.tar.gz" >> /var/log/vpn-backup.log
BKEOF
chmod +x /usr/local/bin/vpn-backup.sh

cat > /etc/cron.d/vpn-backup << 'EOF'
0 4 * * * root /usr/local/bin/vpn-backup.sh
EOF
log "Резервное копирование настроено (ежедневно в 4:00)"

# ================================================================
# Финальный вывод
# ================================================================
SERVER_IP=$(curl -s --max-time 5 https://api.ipify.org 2>/dev/null || true)
[[ -z "$SERVER_IP" ]] && SERVER_IP=$(hostname -I | awk '{print $1}')
[[ -z "$SERVER_IP" ]] && SERVER_IP="<unknown>"

if [[ "$PANEL_MODE" == "domain" ]]; then
    PANEL_URL="https://$PANEL_DOMAIN:$PANEL_NGINX_PORT"
else
    PANEL_URL="https://$SERVER_IP:$PANEL_PORT$PANEL_PATH"
fi

echo ""
echo "${GREEN}╔══════════════════════════════════════════════════════════╗${NC}"
echo "${GREEN}║            УСТАНОВКА ЗАВЕРШЕНА УСПЕШНО                   ║${NC}"
echo "${GREEN}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "${BLUE}━━━ Параметры сервера ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  IP сервера    : $SERVER_IP"
echo "  Reality домен : $REALITY_DOMAIN"
echo ""
echo "${BLUE}━━━ Панель управления 3X-UI ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo "  URL           : $PANEL_URL"
echo "  Логин         : $PANEL_USER"
echo "  Пароль        : $PANEL_PASS"
echo ""
echo "${BLUE}━━━ Порты для inbound (настройте вручную в панели) ━━━━━━━━${NC}"
echo "  VLESS+Reality : порт $XRAY_PORT"
echo "  Trojan+Reality: порт $TROJAN_PORT"
echo ""
echo "${RED}  ⚠  ПОДКЛЮЧЕНИЕ К СЕРВЕРУ — ТОЛЬКО ПО IP ($SERVER_IP), НЕ ПО ДОМЕНУ!${NC}"
echo ""
echo "${YELLOW}  Reality настройки (панель → Inbound → Transmission → Reality):${NC}"
echo "    dest     : tunnel.vk.com:443"
echo "    SNI      : tunnel.vk.com"
echo "    uTLS     : chrome"
echo "    shortId  : (оставить пустым или сгенерировать)"
echo ""
echo "${YELLOW}  Альтернативные targets (если основной деградирует):${NC}"
echo "    ps.userapi.com:443"
echo "    vk.com:443"
echo ""
echo "${YELLOW}  DNS на устройстве: Яндекс (77.88.8.8 / 77.88.8.1), не Google/CF!${NC}"
echo ""
echo "${BLUE}━━━ Состояние сервисов ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
systemctl is-active --quiet x-ui     && echo "  x-ui     : ${GREEN}работает${NC}" || echo "  x-ui     : ${RED}остановлен${NC}"
systemctl is-active --quiet nginx    && echo "  nginx    : ${GREEN}работает${NC}" || echo "  nginx    : ${RED}остановлен${NC}"
systemctl is-active --quiet fail2ban && echo "  fail2ban : ${GREEN}работает${NC}" || echo "  fail2ban : ${RED}остановлен${NC}"
echo ""
echo "${YELLOW}Параметры также сохранены в /root/vpn-install-info.txt${NC}"
echo ""

# Создаём файл с нужными правами ДО записи чувствительных данных
install -m 600 /dev/null /root/vpn-install-info.txt
cat > /root/vpn-install-info.txt << INFOEOF
VPN TOPGUN — параметры установки
====================================
Дата установки    : $(date)
IP сервера        : $SERVER_IP
Reality домен     : $REALITY_DOMAIN

Панель 3X-UI:
  URL             : $PANEL_URL
  Логин           : $PANEL_USER
  Пароль          : $PANEL_PASS

Порты для inbound (настройте в панели):
  VLESS+Reality   : порт $XRAY_PORT
  Trojan+Reality  : порт $TROJAN_PORT

Подключение к серверу — ТОЛЬКО ПО IP ($SERVER_IP), НЕ по домену!

Reality настройки (Transmission → Reality):
  dest     : tunnel.vk.com:443
  SNI      : tunnel.vk.com
  uTLS     : chrome
  shortId  : (оставить пустым или сгенерировать)

Альтернативные targets (если основной деградирует):
  ps.userapi.com:443
  vk.com:443

DNS на устройстве: Яндекс (77.88.8.8 / 77.88.8.1), не Google/CF!
INFOEOF
log "Параметры сохранены в /root/vpn-install-info.txt"
