#!/bin/bash

set -e

BASE_DIR="/opt/nginxbandits"
CONFIG_FILE="${BASE_DIR}/core/nginxbandits.conf"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "[FATAL] NginxBandits configuration not found."
    exit 1
fi

source "$CONFIG_FILE"
source "${BASE_DIR}/lib/system.sh"
source "${BASE_DIR}/lib/installer_utils.sh"

if [ "${EUID}" -ne 0 ]; then
    echo "[FATAL] This installer must be run as root."
    exit 1
fi

echo "======================================================"
echo "        NginxBandits Routing Deployment"
echo "======================================================"

safe_create_dir "${BASE_DIR}/services/routing"

echo "[*] Configuring SSH..."

mkdir -p /etc/ssh/sshd_config.d

cat > /etc/ssh/sshd_config.d/99-nginxbandits.conf <<SSHCONF
Banner /etc/issue.net
MaxStartups 1000:30:2000
ClientAliveInterval 60
ClientAliveCountMax 3
SSHCONF

cat > /etc/issue.net <<'BANNER'
========================================================
                 NGINXBANDITS SERVER
========================================================
 Unauthorized access is prohibited.
 All connections are monitored.
========================================================
BANNER

echo "[*] Validating SSH configuration..."

if command -v sshd >/dev/null 2>&1; then
    sshd -t
fi

echo "[*] Configuring Dropbear..."

cat > /etc/default/dropbear <<DROPBEAR
NO_START=0
DROPBEAR_PORT=${PORT_DROPBEAR}
DROPBEAR_EXTRA_ARGS="-p ${PORT_DROPBEAR_ALT} -w -g -K 60 -I 0 -b /etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
DROPBEAR

echo "[*] Installing WebSocket proxy service..."

cat > /etc/systemd/system/janabitech-ws.service <<SERVICE
[Unit]
Description=NginxBandits WebSocket SSH Proxy
After=network.target ssh.service dropbear.service

[Service]
Type=simple
User=root
WorkingDirectory=${BASE_DIR}/services/routing
ExecStart=/usr/bin/python3 ${BASE_DIR}/services/routing/async-ws-proxy.py
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload

systemctl enable ssh >/dev/null 2>&1 || true
systemctl enable dropbear >/dev/null 2>&1 || true
systemctl enable janabitech-ws >/dev/null 2>&1

echo "[*] Restarting SSH..."

systemctl restart ssh >/dev/null 2>&1 || \
systemctl restart sshd >/dev/null 2>&1 || true

echo "[*] Restarting Dropbear..."

systemctl restart dropbear >/dev/null 2>&1 || true

echo "[*] Starting WebSocket proxy..."

systemctl restart janabitech-ws >/dev/null 2>&1 || true

echo
echo "[+] Routing deployment complete."
echo
echo "SSH       : ${PORT_SSH}"
echo "Dropbear  : ${PORT_DROPBEAR}, ${PORT_DROPBEAR_ALT}"
echo "WebSocket : ${PORT_WS_HTTP}, 8880"
