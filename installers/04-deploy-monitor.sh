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
safe_create_dir "${BASE_DIR}/bin"
safe_create_dir "${BASE_DIR}/logs"

# ------------------------------------------------------
# MONITOR DAEMON
# ------------------------------------------------------

echo "[*] Checking monitoring daemon..."

MONITOR="${BASE_DIR}/services/monitor/daemon.py"

if [ ! -f "$MONITOR" ]; then
    echo "[FATAL] Monitoring daemon not found."
    exit 1
fi

chmod +x "$MONITOR"

# ------------------------------------------------------
# OOKLA SPEEDTEST
# ------------------------------------------------------

if [ ! -x "${BASE_DIR}/bin/speedtest" ]; then

    echo "[*] Installing Ookla Speedtest..."

    SPEEDTEST_URL="https://install.speedtest.net/app/cli/ookla-speedtest-1.2.0-linux-x86_64.tgz"
    SPEEDTEST_TMP="/tmp/nginxbandits-speedtest.tgz"
    SPEEDTEST_DIR="/tmp/nginxbandits-speedtest"

    rm -rf "$SPEEDTEST_DIR"
    mkdir -p "$SPEEDTEST_DIR"

    if wget -qO "$SPEEDTEST_TMP" "$SPEEDTEST_URL"; then

        if tar -xzf "$SPEEDTEST_TMP" -C "$SPEEDTEST_DIR" speedtest 2>/dev/null; then
            if [ -f "${SPEEDTEST_DIR}/speedtest" ]; then
                install -m 755 \
                    "${SPEEDTEST_DIR}/speedtest" \
                    "${BASE_DIR}/bin/speedtest"
            fi
        fi

    fi

    rm -rf "$SPEEDTEST_DIR" "$SPEEDTEST_TMP"

    if [ ! -x "${BASE_DIR}/bin/speedtest" ]; then
        echo "[WARN] Ookla Speedtest could not be installed."
    fi

fi

# ------------------------------------------------------
# BTOP
# ------------------------------------------------------

if [ ! -x "${BASE_DIR}/bin/btop" ]; then

    echo "[*] Installing Btop Monitor..."

    BTOP_URL="https://github.com/aristocratos/btop/releases/download/v1.3.2/btop-x86_64-linux-musl.tbz"
    BTOP_TMP="/tmp/nginxbandits-btop.tbz"
    BTOP_DIR="/tmp/nginxbandits-btop"

    rm -rf "$BTOP_DIR"
    mkdir -p "$BTOP_DIR"

    if wget -qO "$BTOP_TMP" "$BTOP_URL"; then

        if tar -xjf "$BTOP_TMP" -C "$BTOP_DIR" 2>/dev/null; then

            BTOP_BINARY="$(find "$BTOP_DIR" -type f -name btop -print -quit)"

            if [ -n "$BTOP_BINARY" ]; then
                install -m 755 "$BTOP_BINARY" "${BASE_DIR}/bin/btop"
            fi

        fi

    fi

    rm -rf "$BTOP_DIR" "$BTOP_TMP"

    if [ ! -x "${BASE_DIR}/bin/btop" ]; then
        echo "[WARN] Btop could not be installed."
    fi

fi

# ------------------------------------------------------
# SYSTEMD MONITOR SERVICE
# ------------------------------------------------------

echo "[*] Creating monitoring service..."

cat > /etc/systemd/system/janabitech-monitor.service <<SERVICE
[Unit]
Description=NginxBandits Account and Connection Monitor
After=network.target sqlite.target dropbear.service

[Service]
Type=simple
User=root
WorkingDirectory=${BASE_DIR}/services/monitor
ExecStart=/usr/bin/python3 ${MONITOR}
Restart=always
RestartSec=5
ProtectSystem=full
ProtectHome=true
ReadWritePaths=${BASE_DIR}/logs ${BASE_DIR}/core
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

# ------------------------------------------------------
# SYSTEM PACKAGES
# ------------------------------------------------------

echo "[*] Installing monitoring utilities..."

ensure_package sqlite3
ensure_package vnstat

# ------------------------------------------------------
# ENABLE + START
# ------------------------------------------------------

systemctl daemon-reload

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
echo "Service   : janabitech-monitor"

if [ -x "${BASE_DIR}/bin/speedtest" ]; then
    echo "Speedtest : INSTALLED"
else
    echo "Speedtest : NOT INSTALLED"
fi

if [ -x "${BASE_DIR}/bin/btop" ]; then
    echo "Btop      : INSTALLED"
else
    echo "Btop      : NOT INSTALLED"
fi

echo "Status    : ACTIVE"
echo
