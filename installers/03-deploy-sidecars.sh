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
echo "        NginxBandits Sidecar Deployment"
echo "======================================================"

safe_create_dir "${BASE_DIR}/binaries"
safe_create_dir "${BASE_DIR}/core/keys"

echo "[*] Detecting network interface..."

IFACE="$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')"

if [ -z "$IFACE" ]; then
    echo "[FATAL] Could not determine default network interface."
    exit 1
fi

echo "[+] Interface: $IFACE"

# ------------------------------------------------------
# DANTE SOCKS5
# ------------------------------------------------------

echo "[*] Configuring Dante SOCKS5..."

cat > /etc/danted.conf <<DANTE
logoutput: syslog

user.privileged: root
user.unprivileged: nobody

internal: 0.0.0.0 port = ${PORT_SOCKS}
external: ${IFACE}

socksmethod: username
clientmethod: none

client pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}

socks pass {
    from: 0.0.0.0/0 to: 0.0.0.0/0
    log: error
}
DANTE

systemctl enable danted >/dev/null 2>&1 || true
systemctl restart danted >/dev/null 2>&1 || true

# ------------------------------------------------------
# UDP CUSTOM
# ------------------------------------------------------

echo "[*] Configuring UDP Custom..."

safe_create_dir /etc/udp-custom

cat > /etc/udp-custom/config.json <<UDPJSON
{
  "listen": ":${PORT_UDP_CUSTOM}",
  "stream_buffer": 33554432,
  "receive_buffer": 83886080,
  "auth": {
    "mode": "passwords"
  }
}
UDPJSON

if [ ! -x "${BASE_DIR}/bin/udp-custom" ]; then
    echo "[WARN] UDP Custom binary not found."
else
    chmod +x "${BASE_DIR}/bin/udp-custom"
fi

echo "[*] Creating UDP Custom service..."

cat > /etc/systemd/system/janabitech-udp-custom.service <<SERVICE
[Unit]
Description=NginxBandits UDP Custom
After=network.target

[Service]
Type=simple
User=root
ExecStart=${BASE_DIR}/bin/udp-custom server -exclude 53,${PORT_DNSTT}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable janabitech-udp-custom >/dev/null 2>&1 || true

# ------------------------------------------------------
# DNSTT
# ------------------------------------------------------

echo "[*] Preparing DNSTT keys..."

DNSTT_BIN="${BASE_DIR}/bin/dnstt-server"

if [ ! -x "$DNSTT_BIN" ]; then
    echo "[WARN] DNSTT server binary not found."
else
    chmod +x "$DNSTT_BIN"

    if [ ! -s "${BASE_DIR}/core/keys/dnstt.key" ] || \
       [ ! -s "${BASE_DIR}/core/keys/dnstt.pub" ]; then

        "$DNSTT_BIN" \
            -gen-key \
            -privkey-file "${BASE_DIR}/core/keys/dnstt.key" \
            -pubkey-file "${BASE_DIR}/core/keys/dnstt.pub"
    fi
fi

if [ -f "${BASE_DIR}/core/keys/dnstt.key" ]; then
    chmod 600 "${BASE_DIR}/core/keys/dnstt.key"
fi

if [ -f "${BASE_DIR}/core/keys/dnstt.pub" ]; then
    chmod 644 "${BASE_DIR}/core/keys/dnstt.pub"
fi

echo "[*] Creating DNSTT service..."

cat > /etc/systemd/system/janabitech-dnstt.service <<SERVICE
[Unit]
Description=NginxBandits DNSTT Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=${DNSTT_BIN} -udp :${PORT_DNSTT} -privkey-file ${BASE_DIR}/core/keys/dnstt.key ${NS_DOMAIN} 127.0.0.1:${PORT_SSH}
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable janabitech-dnstt >/dev/null 2>&1 || true

# ------------------------------------------------------
# FIREWALL
# ------------------------------------------------------

echo "[*] Configuring firewall rules..."

iptables -C INPUT -p udp --dport "${PORT_DNSTT}" -j ACCEPT 2>/dev/null || \
iptables -I INPUT -p udp --dport "${PORT_DNSTT}" -j ACCEPT

iptables -C INPUT -p udp --dport "${PORT_UDP_CUSTOM}" -j ACCEPT 2>/dev/null || \
iptables -I INPUT -p udp --dport "${PORT_UDP_CUSTOM}" -j ACCEPT

iptables -t nat -C PREROUTING -p udp --dport 53 \
    -j REDIRECT --to-ports "${PORT_DNSTT}" 2>/dev/null || \
iptables -t nat -I PREROUTING -p udp --dport 53 \
    -j REDIRECT --to-ports "${PORT_DNSTT}"

netfilter-persistent save >/dev/null 2>&1 || true

# ------------------------------------------------------
# START SERVICES
# ------------------------------------------------------

echo "[*] Starting UDP Custom..."

if [ -x "${BASE_DIR}/bin/udp-custom" ]; then
    systemctl restart janabitech-udp-custom >/dev/null 2>&1 || true
fi

echo "[*] Starting DNSTT..."

if [ -x "$DNSTT_BIN" ] && [ -s "${BASE_DIR}/core/keys/dnstt.key" ]; then
    systemctl restart janabitech-dnstt >/dev/null 2>&1 || true
fi

echo
echo "[+] Sidecar deployment complete."
echo
echo "SOCKS5     : ${PORT_SOCKS}"
echo "UDP Custom : ${PORT_UDP_CUSTOM}"
echo "DNSTT      : ${PORT_DNSTT}"
echo
