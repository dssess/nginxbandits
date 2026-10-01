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
echo "        NginxBandits Monitoring Deployment"
echo "======================================================"

safe_create_dir "${BASE_DIR}/services/monitor"
safe_create_dir "${BASE_DIR}/logs"

echo "[*] Checking monitoring daemon..."

if [ ! -f "${BASE_DIR}/services/monitor/daemon.py" ]; then
    echo "[FATAL] Monitoring daemon not found."
    exit 1
fi

chmod +x "${BASE_DIR}/services/monitor/daemon.py"

echo "[*] Creating monitoring service..."

cat > /etc/systemd/system/janabitech-monitor.service <<SERVICE
[Unit]
Description=NginxBandits Account and Connection Monitor
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=${BASE_DIR}/services/monitor
ExecStart=/usr/bin/python3 ${BASE_DIR}/services/monitor/daemon.py
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload

echo "[*] Installing monitoring utilities..."

ensure_package btop
ensure_package vnstat

echo "[*] Enabling monitor..."

systemctl enable janabitech-monitor >/dev/null 2>&1

echo "[*] Starting monitor..."

systemctl restart janabitech-monitor

sleep 2

if systemctl is-active --quiet janabitech-monitor; then
    echo "[+] Monitor service is ACTIVE."
else
    echo "[FATAL] Monitor service failed to start."
    systemctl --no-pager --full status janabitech-monitor || true
    exit 1
fi

echo
echo "[+] Monitoring deployment complete."
echo
echo "Service : janabitech-monitor"
echo "Status  : ACTIVE"
