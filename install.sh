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
echo -e "${CYAN}Private GitHub repository detected.${NC}"
echo "Enter a GitHub Personal Access Token with access"
echo "to the dssess/nginxbandits repository."
echo

read -r -s -p "GitHub Token: " GITHUB_TOKEN
echo

if [ -z "$GITHUB_TOKEN" ]; then
    echo -e "${RED}[FATAL] GitHub token cannot be empty.${NC}"
    exit 1
fi

rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"

cleanup() {
    unset GITHUB_TOKEN
    unset GIT_ASKPASS
    rm -f "$TMP_DIR/git-askpass.sh"
}

trap cleanup EXIT

cat > "$TMP_DIR/git-askpass.sh" <<'ASKPASS'
#!/bin/sh

case "$1" in
    *Username*)
        printf '%s\n' "x-access-token"
        ;;
    *Password*)
        printf '%s\n' "$GITHUB_TOKEN"
        ;;
esac
ASKPASS

chmod 700 "$TMP_DIR/git-askpass.sh"

export GITHUB_TOKEN
export GIT_ASKPASS="$TMP_DIR/git-askpass.sh"

echo
echo -e "${CYAN}[*] Downloading NginxBandits...${NC}"

if ! git clone --depth 1 "$REPO" "$TMP_DIR/repo" >/dev/null 2>&1; then
    echo -e "${RED}[FATAL] Could not clone the private repository.${NC}"
    echo "Check that the token has access to dssess/nginxbandits."
    exit 1
fi

echo -e "${CYAN}[*] Deploying NginxBandits files...${NC}"

mkdir -p "$BASE_DIR"

cp -a "$TMP_DIR/repo/." "$BASE_DIR/"

find \
    "$BASE_DIR/bin" \
    "$BASE_DIR/menus" \
    "$BASE_DIR/installers" \
    "$BASE_DIR/services" \
    -type f \
    -exec chmod +x {} \; \
    2>/dev/null || true

echo -e "${CYAN}[*] Creating legacy compatibility path...${NC}"

if [ -e /opt/janabitech ] && [ ! -L /opt/janabitech ]; then
    echo -e "${YELLOW}[WARN] /opt/janabitech already exists as a directory.${NC}"
else
    ln -sfn "$BASE_DIR" /opt/janabitech
fi

mkdir -p "$BASE_DIR/core"
mkdir -p "$BASE_DIR/logs"
touch "$BASE_DIR/logs/nginxbandits.log"
ln -sfn "$BASE_DIR/logs/nginxbandits.log" "$BASE_DIR/logs/janabitech.log"
mkdir -p "$BASE_DIR/core/keys"

if [ -f "$BASE_DIR/core/nginxbandits.conf" ]; then
    ln -sfn \
        "$BASE_DIR/core/nginxbandits.conf" \
        "$BASE_DIR/core/janabitech.conf"
fi

if [ -f "$BASE_DIR/bin/nginxbandits" ]; then
    chmod +x "$BASE_DIR/bin/nginxbandits"

    ln -sfn \
        "$BASE_DIR/bin/nginxbandits" \
        "$BASE_DIR/bin/janabitech"
fi

if [ -f "$BASE_DIR/logs/nginxbandits.log" ]; then
    ln -sfn \
        "$BASE_DIR/logs/nginxbandits.log" \
        "$BASE_DIR/logs/janabitech.log"
fi

if [ ! -f "$BASE_DIR/core/server_geo.env" ]; then
    cat > "$BASE_DIR/core/server_geo.env" <<GEO
SERVER_COUNTRY=""
SERVER_CITY=""
SERVER_ISP=""
GEO
fi

chmod 600 "$BASE_DIR/core/server_geo.env"

echo -e "${CYAN}[*] Installing global commands...${NC}"

ln -sfn \
    "$BASE_DIR/bin/nginxbandits" \
    /usr/local/bin/nginxbandits

ln -sfn \
    "$BASE_DIR/bin/nginxbandits" \
    /usr/local/bin/janabitech

if [ -f "$BASE_DIR/menus/main_menu.sh" ]; then
    chmod +x "$BASE_DIR/menus/main_menu.sh"

    ln -sfn \
        "$BASE_DIR/menus/main_menu.sh" \
        /usr/local/sbin/menu
fi

PHASES=(
    "01-core-setup.sh"
    "02-deploy-routing.sh"
    "03-deploy-sidecars.sh"
    "04-deploy-monitor.sh"
)

for PHASE in "${PHASES[@]}"; do

    PHASE_FILE="$BASE_DIR/installers/$PHASE"

    if [ ! -f "$PHASE_FILE" ]; then
        echo -e "${RED}[FATAL] Missing installer phase: $PHASE${NC}"
        exit 1
    fi

    chmod +x "$PHASE_FILE"

    echo
    echo -e "${YELLOW}>>> Executing Phase: $PHASE <<<${NC}"
    echo

    if ! "$PHASE_FILE"; then
        echo
        echo -e "${RED}[FATAL] Phase $PHASE failed.${NC}"
        echo -e "${RED}Installation stopped to protect the server.${NC}"
        exit 1
    fi

done

echo
echo -e "${CYAN}[*] Performing final installation checks...${NC}"

if [ ! -x "$BASE_DIR/bin/nginxbandits" ]; then
    echo -e "${RED}[FATAL] NginxBandits CLI was not installed correctly.${NC}"
    exit 1
fi

if [ ! -x "$BASE_DIR/menus/main_menu.sh" ]; then
    echo -e "${RED}[FATAL] Main menu was not installed correctly.${NC}"
    exit 1
fi

if [ ! -L /opt/janabitech ]; then
    echo -e "${RED}[FATAL] Legacy compatibility path was not created.${NC}"
    exit 1
fi

if [ ! -L /usr/local/bin/nginxbandits ]; then
    echo -e "${RED}[FATAL] NginxBandits command link was not created.${NC}"
    exit 1
fi

if [ ! -L /usr/local/sbin/menu ]; then
    echo -e "${RED}[FATAL] Menu command link was not created.${NC}"
    exit 1
fi

BASHRC="/root/.bashrc"

if ! grep -qF '# NginxBandits interactive menu' "$BASHRC" 2>/dev/null; then

    cat >> "$BASHRC" <<'BASHRC'

# NginxBandits interactive menu
if [[ $- == *i* ]] && command -v menu >/dev/null 2>&1; then
    menu
fi
BASHRC

fi

rm -rf "$TMP_DIR"

echo
echo -e "${CYAN}======================================================${NC}"
echo -e "${GREEN}       NGINXBANDITS INSTALLATION COMPLETE${NC}"
echo -e "${CYAN}======================================================${NC}"
echo
echo -e "Installation : ${GREEN}${BASE_DIR}${NC}"
echo -e "Legacy path  : ${GREEN}/opt/janabitech${NC}"
echo -e "CLI          : ${GREEN}nginxbandits${NC}"
echo -e "Legacy CLI   : ${GREEN}janabitech${NC}"
echo -e "Menu         : ${GREEN}menu${NC}"
echo
echo -e "Type ${GREEN}menu${NC} to open the server management panel."
echo
