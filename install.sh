#!/bin/bash

set -e

REPO="https://github.com/dssess/nginxbandits.git"
BASE_DIR="/opt/nginxbandits"
TMP_DIR="/root/nginxbandits-install"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

clear

echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}             NGINXBANDITS SERVER SYSTEM${NC}"
echo -e "${CYAN}======================================================${NC}"
echo

if [ "${EUID}" -ne 0 ]; then
    echo -e "${RED}[FATAL] Please run this installer as root.${NC}"
    exit 1
fi

if ! command -v git >/dev/null 2>&1; then
    echo -e "${YELLOW}[*] Git not found. Installing Git...${NC}"
    apt-get update -y
    DEBIAN_FRONTEND=noninteractive apt-get install -y git ca-certificates
fi

echo
echo -e "${CYAN}[*] Preparing NginxBandits installer...${NC}"

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

cleanup() {
    rm -rf "$TMP_DIR"
}

trap cleanup EXIT

echo -e "${CYAN}[*] Downloading NginxBandits...${NC}"

if ! git clone --depth 1 "$REPO" "$TMP_DIR/repo" >/dev/null 2>&1; then
    echo -e "${RED}[FATAL] Could not download the NginxBandits repository.${NC}"
    echo "Check that the repository is public and accessible."
    exit 1
fi

echo -e "${CYAN}[*] Deploying NginxBandits files...${NC}"

mkdir -p "$BASE_DIR"
cp -a "$TMP_DIR/repo/." "$BASE_DIR/"

echo -e "${CYAN}[*] Preparing installer permissions...${NC}"

chmod +x "$BASE_DIR/install.sh"
find "$BASE_DIR/bin" "$BASE_DIR/menus" "$BASE_DIR/installers" "$BASE_DIR/lib" \
    -type f -name "*.sh" -exec chmod +x {} \;

echo -e "${CYAN}[*] Running NginxBandits installation phases...${NC}"

PHASES=(
    "$BASE_DIR/installers/01-core-setup.sh"
    "$BASE_DIR/installers/02-deploy-routing.sh"
    "$BASE_DIR/installers/03-deploy-sidecars.sh"
    "$BASE_DIR/installers/04-deploy-monitor.sh"
)

for phase in "${PHASES[@]}"; do
    if [ ! -f "$phase" ]; then
        echo -e "${RED}[FATAL] Missing installer phase: $phase${NC}"
        exit 1
    fi

    echo -e "${CYAN}[*] Running $(basename "$phase")...${NC}"
    bash "$phase"
done

echo
echo -e "${CYAN}[*] Creating compatibility paths...${NC}"

ln -sfn "$BASE_DIR" /opt/janabitech
ln -sfn "$BASE_DIR/core/nginxbandits.conf" "$BASE_DIR/core/janabitech.conf"
ln -sfn "$BASE_DIR/bin/nginxbandits" "$BASE_DIR/bin/janabitech"
ln -sfn "$BASE_DIR/logs/nginxbandits.log" "$BASE_DIR/logs/janabitech.log"

ln -sfn "$BASE_DIR/bin/nginxbandits" /usr/local/bin/nginxbandits
ln -sfn "$BASE_DIR/bin/janabitech" /usr/local/bin/janabitech
ln -sfn "$BASE_DIR/menus/main_menu.sh" /usr/local/sbin/menu

if ! grep -qF '# NginxBandits interactive menu' /root/.bashrc 2>/dev/null; then
    cat >> /root/.bashrc <<'BASHRC'

# NginxBandits interactive menu
if [[ $- == *i* ]] && command -v menu >/dev/null 2>&1; then
    menu
fi
BASHRC
fi

echo
echo -e "${GREEN}======================================================${NC}"
echo -e "${GREEN}        NGINXBANDITS INSTALLATION COMPLETE${NC}"
echo -e "${GREEN}======================================================${NC}"
echo
echo "Installation : $BASE_DIR"
echo "Legacy path  : /opt/janabitech"
echo "CLI          : nginxbandits"
echo "Legacy CLI   : janabitech"
echo "Menu         : menu"
echo
echo -e "${GREEN}NginxBandits is ready.${NC}"
