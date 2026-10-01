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
safe_create_dir "${BASE_DIR}/core/keys"

# ------------------------------------------------------
# SSH
# ------------------------------------------------------

echo "[*] Configuring OpenSSH..."

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

if command -v sshd >/dev/null 2>&1; then
    echo "[*] Validating SSH configuration..."
    sshd -t
fi

# ------------------------------------------------------
# DROPBEAR
# ------------------------------------------------------

echo "[*] Configuring Dropbear..."

cat > /etc/default/dropbear <<DROPBEAR
NO_START=0
DROPBEAR_PORT=${PORT_DROPBEAR}
DROPBEAR_EXTRA_ARGS="-p ${PORT_DROPBEAR_ALT} -w -g -K 60 -I 0 -b /etc/issue.net"
DROPBEAR_RECEIVE_WINDOW=65536
DROPBEAR

# ------------------------------------------------------
# WEBSOCKET PROXY
# ------------------------------------------------------

echo "[*] Configuring Async WebSocket proxy..."

WS_PROXY="${BASE_DIR}/services/routing/async-ws-proxy.py"

if [ ! -f "$WS_PROXY" ]; then
    echo "[FATAL] WebSocket proxy not found."
    exit 1
fi

chmod +x "$WS_PROXY"

cat > /etc/systemd/system/janabitech-ws.service <<SERVICE
[Unit]
Description=NginxBandits Async WebSocket SSH Proxy
After=network.target ssh.service dropbear.service

[Service]
Type=simple
User=root
WorkingDirectory=${BASE_DIR}/services/routing
ExecStart=/usr/bin/python3 ${WS_PROXY}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

# ------------------------------------------------------
# STUNNEL
# ------------------------------------------------------

echo "[*] Configuring Stunnel TLS bridging..."

ensure_tls_cert "$PRIMARY_DOMAIN"

cat > /etc/stunnel/stunnel.conf <<STUNNEL
pid = /var/run/stunnel.pid
cert = ${BASE_DIR}/core/keys/stunnel.pem
client = no

socket = a:SO_REUSEADDR=1
socket = a:SO_KEEPALIVE=1
socket = l:TCP_NODELAY=1
socket = r:TCP_NODELAY=1

[ssh-ws-ssl]
accept = ${PORT_WS_HTTPS}
connect = 127.0.0.1:${PORT_WS_HTTP}

[dropbear-ssl-447]
accept = ${PORT_SSL_ALT1}
connect = 127.0.0.1:${PORT_SSH}

[dropbear-ssl-777]
accept = ${PORT_SSL_ALT2}
connect = 127.0.0.1:${PORT_SSH}
STUNNEL

if [ -f /etc/default/stunnel4 ]; then
    if grep -q '^ENABLED=' /etc/default/stunnel4; then
        sed -i 's/^ENABLED=.*/ENABLED=1/' /etc/default/stunnel4
    else
        echo 'ENABLED=1' >> /etc/default/stunnel4
    fi
fi

# ------------------------------------------------------
# SYSTEMD
# ------------------------------------------------------

echo "[*] Reloading systemd..."

systemctl daemon-reload

systemctl enable ssh >/dev/null 2>&1 || true
systemctl enable ssh.socket >/dev/null 2>&1 || true
systemctl enable dropbear >/dev/null 2>&1 || true
systemctl enable janabitech-ws >/dev/null 2>&1
systemctl enable stunnel4 >/dev/null 2>&1 || true

echo "[*] Restarting OpenSSH..."

systemctl restart ssh >/dev/null 2>&1 || \
systemctl restart sshd >/dev/null 2>&1 || true

systemctl restart ssh.socket >/dev/null 2>&1 || true

echo "[*] Restarting Dropbear..."

systemctl restart dropbear >/dev/null 2>&1 || true

echo "[*] Starting WebSocket proxy..."

systemctl restart janabitech-ws >/dev/null 2>&1 || true

echo "[*] Starting Stunnel..."

systemctl restart stunnel4 >/dev/null 2>&1 || true

echo
echo "[+] Routing deployment complete."
echo
echo "SSH       : ${PORT_SSH}"
echo "Dropbear  : ${PORT_DROPBEAR}, ${PORT_DROPBEAR_ALT}"
echo "WebSocket : ${PORT_WS_HTTP}, ${PORT_WS_HTTPS}"
echo "SSL Alt   : ${PORT_SSL_ALT1}, ${PORT_SSL_ALT2}"
echo
