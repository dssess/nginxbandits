#!/bin/bash

set -e

BASE_DIR="/opt/nginxbandits"
CONFIG_FILE="${BASE_DIR}/core/nginxbandits.conf"

source "${BASE_DIR}/lib/system.sh" 2>/dev/null || true
source "${BASE_DIR}/lib/installer_utils.sh" 2>/dev/null || true

if [ "${EUID}" -ne 0 ]; then
    echo "[FATAL] This installer must be run as root."
    exit 1
fi

echo "======================================================"
echo "        NginxBandits Core Infrastructure"
echo "======================================================"

safe_create_dir "${BASE_DIR}/bin"
safe_create_dir "${BASE_DIR}/core"
safe_create_dir "${BASE_DIR}/core/keys"
safe_create_dir "${BASE_DIR}/lib"
safe_create_dir "${BASE_DIR}/logs"
safe_create_dir "${BASE_DIR}/menus"
safe_create_dir "${BASE_DIR}/services"
safe_create_dir "${BASE_DIR}/services/monitor"
safe_create_dir "${BASE_DIR}/services/routing"
safe_create_dir "${BASE_DIR}/binaries"

echo
echo "[*] Updating package index..."
DEBIAN_FRONTEND=noninteractive apt-get update -y

PACKAGES=(
    curl
    wget
    git
    cron
    iptables
    iptables-persistent
    lsof
    tar
    unzip
    uuid-runtime
    ca-certificates
    openssl
    sqlite3
    bzip2
    dropbear
    stunnel4
    dante-server
    python3
    vnstat
)

echo
echo "[*] Installing required packages..."

for package in "${PACKAGES[@]}"; do
    ensure_package "$package"
done

echo
echo "[*] Configuring kernel networking..."

cat > /etc/sysctl.d/99-nginxbandits.conf <<'SYSCTL'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.ipv4.ip_forward=1
SYSCTL

sysctl --system >/dev/null 2>&1 || true

if ! grep -qxF '/bin/false' /etc/shells; then
    echo '/bin/false' >> /etc/shells
fi

echo
echo "[*] Preparing NginxBandits configuration..."

if [ ! -f "$CONFIG_FILE" ]; then
    read -r -p "Primary VPN Domain: " DOMAIN
    read -r -p "Nameserver Domain: " NS_DOMAIN

    cat > "$CONFIG_FILE" <<CONFIG
BASE_DIR="/opt/nginxbandits"
PRIMARY_DOMAIN="$DOMAIN"
NS_DOMAIN="$NS_DOMAIN"

MAX_LOGINS_DEFAULT=2

PORT_SSH=22
PORT_DROPBEAR=109
PORT_DROPBEAR_ALT=143
PORT_WS_HTTP=80
PORT_WS_HTTPS=443
PORT_SOCKS=1080
PORT_UDP_CUSTOM=36712
PORT_UDPGW=7300
PORT_DNSTT=5300
PORT_SSL_ALT1=447
PORT_SSL_ALT2=777

DB_PATH="/opt/nginxbandits/core/database.db"
LOG_DIR="/opt/nginxbandits/logs"

FOOTER_MSG=""
CONFIG
fi

source "$CONFIG_FILE"

echo
echo "[*] Initializing database..."

source "${BASE_DIR}/lib/db.sh"
init_database

echo
echo "[*] Configuring log rotation..."

cat > /etc/logrotate.d/nginxbandits <<LOGROTATE
${BASE_DIR}/logs/nginxbandits.log {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
LOGROTATE

echo
echo "[+] NginxBandits core setup complete."
