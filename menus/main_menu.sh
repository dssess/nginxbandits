#!/bin/bash
source /opt/janabitech/core/janabitech.conf
source /opt/janabitech/lib/system.sh

# --- Root Enforcement ---
if [ "${EUID}" -ne 0 ]; then
    echo -e "\033[0;31m[FATAL] You must be root to access the Virtarixtech Dashboard.\033[0m"
    echo -e "\033[0;33mType this command to become root: sudo su -\033[0m"
    exit 1
fi

# --- ANSI Color Palette ---
RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
NC='\033[0m'
BOLD='\033[1m'

draw_top() { echo -e "${CYAN}┌────────────────────────────────────────────────────────┐${NC}"; }
draw_mid() { echo -e "${CYAN}├────────────────────────────────────────────────────────┤${NC}"; }
draw_bot() { echo -e "${CYAN}└────────────────────────────────────────────────────────┘${NC}"; }
draw_line() { echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# --- Live Data Harvesters ---
fetch_server_geo() {
    local geo_file="/opt/janabitech/core/server_geo.env"
    
    # Only fetch the data if the cache file doesn't exist yet
    if [ ! -f "$geo_file" ]; then
        # 1. Get the public IP
        local ip=$(curl -sS -4 ipv4.icanhazip.com 2>/dev/null)
        
        # 2. Fetch Geo data using 'org' instead of 'isp'
        local geo_data=$(curl -sS "http://ip-api.com/line/$ip?fields=country,org" 2>/dev/null)
        
        # 3. Parse the lines safely
        local country=$(echo "$geo_data" | sed -n '1p')
        
        # 4. Extract org and strip the trailing ' (region)' text using sed
        local org_clean=$(echo "$geo_data" | sed -n '2p' | sed 's/ *(.*)//')
        
        # 5. Save to the core architecture directory
        echo "SERVER_IP=\"${ip:-Unknown}\"" > "$geo_file"
        echo "SERVER_COUNTRY=\"${country:-Unknown}\"" >> "$geo_file"
        echo "SERVER_ISP=\"${org_clean:-Unknown}\"" >> "$geo_file"
    fi
}

get_system_stats() {
    # Existing dynamic stats
    OS_INFO=$(grep -w PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')
    UPTIME=$(uptime -p | sed 's/up //')
    RAM_USED=$(free -m | awk 'NR==2{print $3}')
    RAM_TOTAL=$(free -m | awk 'NR==2{print $2}')
    CPU_USAGE=$(top -bn1 | grep "Cpu(s)" | sed "s/.*, *\([0-9.]*\)%* id.*/\1/" | awk '{print 100 - $1"%"}')
    
    # New Static Geo Stats
    fetch_server_geo
    source /opt/janabitech/core/server_geo.env 2>/dev/null
    
    # Server Bandwidth Stats
    BW_TODAY="0.00 MB"
    BW_MONTH="0.00 MB"
    if command -v vnstat &>/dev/null; then
        # Use default interface. vnstat --oneline returns semicolon-separated values
        # Field 6: Total Today, Field 11: Total Month
        local vn_data=$(vnstat --oneline 2>/dev/null)
        if [[ "$vn_data" =~ ^[0-9]+ ]]; then
            BW_TODAY=$(echo "$vn_data" | cut -d';' -f6)
            BW_MONTH=$(echo "$vn_data" | cut -d';' -f11)
        fi
    fi
}

get_db_stats() {
    TOTAL_USERS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
    ACTIVE_USERS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users WHERE status='ACTIVE';" 2>/dev/null || echo "0")
    EXPIRED_USERS=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users WHERE status='EXPIRED';" 2>/dev/null || echo "0")
}

check_service() {
    if systemctl is-active --quiet "$1" 2>/dev/null; then
        echo -e "${GREEN}[ON]${NC}"
    else
        echo -e "${RED}[OFF]${NC}"
    fi
}

pause() {
    echo ""
    read -n 1 -s -r -p "Press any key to return..."
}

# ==========================================================
# [01] SSH PANEL
# ==========================================================
menu_ssh_panel() {
    while true; do
        clear
        draw_line
        echo -e "                   ${BOLD}SSH ACCOUNT PANEL${NC}                   "
        draw_line
        echo -e "  ${CYAN}[01]${NC} Create SSH Account"
        echo -e "  ${CYAN}[02]${NC} Create Trial SSH"
        echo -e "  ${CYAN}[03]${NC} Renew SSH Account"
        echo -e "  ${CYAN}[04]${NC} Delete SSH Account"
        echo -e "  ${CYAN}[05]${NC} Check Online Users"
        echo -e "  ${CYAN}[06]${NC} List Members"
        echo -e "  ${CYAN}[07]${NC} User Details (Print Credentials)"
        echo -e "  ${CYAN}[08]${NC} Locked/Banned Users"
        echo -e ""
        echo -e "  ${RED}[00]${NC} Return to Main Menu"
        draw_line
        read -p " Select Option : " opt

        case $opt in
            1) execute_add_user ;;
            2) execute_trial_user ;;
            3) execute_renew_user ;;
            4) execute_del_user ;;
            5) execute_online_users ;;
            6) execute_list_users ;;
            7) execute_user_details ;;
            8) execute_locked_users ;;
            0) return ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

execute_add_user() {
    while true; do
        clear
        echo -e "${CYAN}=== CREATE SSH ACCOUNT ===${NC}"
        
        read -p "Username: " USERNAME
        if [[ -z "$USERNAME" ]]; then echo -e "${RED}[ERROR] Username cannot be empty.${NC}"; sleep 1.5; continue; fi
        
        # Auto-generate password if left blank
        local rand_pass=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c8)
        read -p "Password [default: random]: " PASSWORD
        PASSWORD=${PASSWORD:-$rand_pass}
        
        read -p "Duration (Days) [default: 30]: " DAYS
        DAYS=${DAYS:-30}

        read -p "Max Simultaneous Logins (0 = Unlimited) [Default: 2]: " MAX_LOGINS
        MAX_LOGINS=${MAX_LOGINS:-2}

        read -p "Bandwidth Limit in GB (0 = Unlimited) [Default: 0]: " BW_LIMIT
        BW_LIMIT=${BW_LIMIT:-0}

        /opt/janabitech/bin/janabitech user add "$USERNAME" "$PASSWORD" "$DAYS" "$MAX_LOGINS" "$BW_LIMIT" > /dev/null 2>&1
        API_STATUS=$?
        
        if [ $API_STATUS -eq 2 ]; then
            echo -e "\n${ORANGE}[!] User '${USERNAME}' already exists.${NC}"
            read -p "Do you want to create another user? (y/n): " RETRY
            if [[ "$RETRY" =~ ^[Yy] ]]; then continue; else return; fi
        elif [ $API_STATUS -ne 0 ]; then
            echo -e "\n${RED}[-] Failed to create account. Ensure username is 3-32 chars.${NC}"; pause; return
        fi
        break
    done
    print_user_receipt "$USERNAME" "$PASSWORD" "$DAYS" "days" "$MAX_LOGINS" "$BW_LIMIT"
}

execute_trial_user() {
    clear
    echo -e "${CYAN}=== CREATE TRIAL SSH ACCOUNT ===${NC}"
    
    # Auto-generate trial user and random password
    USERNAME="trial$((RANDOM % 9000 + 1000))"
    PASSWORD=$(< /dev/urandom tr -dc _A-Z-a-z-0-9 | head -c6)
    
    echo -e "Generated Username : ${GREEN}${USERNAME}${NC}"
    echo -e "Generated Password : ${GREEN}${PASSWORD}${NC}\n"
    
    read -p "Duration in Hours [default: 2]: " HOURS
    HOURS=${HOURS:-2}

    read -p "Max Simultaneous Logins (0 = Unlimited) [Default: 2]: " MAX_LOGINS
    MAX_LOGINS=${MAX_LOGINS:-2}

    read -p "Bandwidth Limit in GB (0 = Unlimited) [Default: 0]: " BW_LIMIT
    BW_LIMIT=${BW_LIMIT:-0}

    /opt/janabitech/bin/janabitech user trial "$USERNAME" "$PASSWORD" "$HOURS" "$MAX_LOGINS" "$BW_LIMIT" > /dev/null 2>&1
    print_user_receipt "$USERNAME" "$PASSWORD" "$HOURS" "hours" "$MAX_LOGINS" "$BW_LIMIT"
}

execute_renew_user() {
    clear
    echo -e "${CYAN}=== RENEW SSH ACCOUNT ===${NC}"
    select_user_from_list
    if [[ -z "$FINAL_USERNAME" ]]; then return; fi

    local OLD_DATE_FORMATTED=$(date -d "$FINAL_EXPIRY" +"%B %d, %Y" 2>/dev/null || echo "$FINAL_EXPIRY")

    echo -e "\nUser: ${GREEN}${FINAL_USERNAME}${NC} | Current Expiry: ${ORANGE}${OLD_DATE_FORMATTED}${NC}"
    echo -e "Enter days to add (e.g., 30) or days to deduct (e.g., -5):"
    read -p "Modification (Days): " MOD_DAYS

    # Ensure the input is a valid number (positive or negative)
    if ! [[ "$MOD_DAYS" =~ ^-?[0-9]+$ ]]; then
        echo -e "${RED}[-] Invalid input. Please enter a valid number.${NC}"
        sleep 2; return
    fi

    # Call the API silently
    /opt/janabitech/bin/janabitech user renew "$FINAL_USERNAME" "$MOD_DAYS" > /dev/null 2>&1
    
    # Fetch the newly updated expiry from the database
    local NEW_EXPIRY=$(sqlite3 "$DB_PATH" "SELECT expiry_date FROM users WHERE username='$FINAL_USERNAME';" 2>/dev/null)
    local NEW_DATE_FORMATTED=$(date -d "$NEW_EXPIRY" +"%B %d, %Y" 2>/dev/null || echo "$NEW_EXPIRY")
    
    # Color code the modification output
    local MOD_DISPLAY=""
    if [ "$MOD_DAYS" -lt 0 ]; then
        MOD_DISPLAY="${RED}${MOD_DAYS} Days${NC}"
    else
        MOD_DISPLAY="${GREEN}+${MOD_DAYS} Days${NC}"
    fi

    clear
    echo -e "${GREEN}Account renewed successfully${NC}       "
    draw_line
    echo -e "Username      : ${GREEN}${FINAL_USERNAME}${NC}"
    echo -e "Modification  : ${MOD_DISPLAY}"
    echo -e "Old Expiry    : ${ORANGE}${OLD_DATE_FORMATTED}${NC}"
    echo -e "New Expiry    : ${GREEN}${NEW_DATE_FORMATTED}${NC}"
    draw_line
    
    pause
}

execute_del_user() {
    clear
    echo -e "${CYAN}=== DELETE SSH ACCOUNT(S) ===${NC}"
    
    mapfile -t USER_LIST < <(sqlite3 -separator '|' "$DB_PATH" "SELECT username FROM users;")
    local user_count=${#USER_LIST[@]}
    
    if [ "$user_count" -eq 0 ]; then
        echo -e "\n${ORANGE}[!] No users found in the database.${NC}"; pause; return
    fi

    draw_line
    printf "${BOLD}%-5s | %-15s${NC}\n" "S/N" "USERNAME"
    draw_line
    
    local i=1
    for uname in "${USER_LIST[@]}"; do
        printf "${GREEN}%-5s${NC} | ${CYAN}%-15s${NC}\n" "$i" "$uname"
        ((i++))
    done
    draw_line
    
    echo -e "Enter S/N(s) separated by commas or ranges (e.g., 1,3 or 4-6)"
    read -p "Select targets: " TARGET_INPUT
    if [[ -z "$TARGET_INPUT" ]]; then return; fi

    # Parse ranges and commas into a distinct list of IDs
    local TO_DELETE=()
    local parsed_list=$(echo "$TARGET_INPUT" | awk -F, '{
        for(i=1; i<=NF; i++) {
            if ($i ~ /-/) { split($i, a, "-"); for(j=a[1]; j<=a[2]; j++) printf "%s ", j } 
            else { printf "%s ", $i }
        }
    }')

    for sn in $parsed_list; do
        if [[ "$sn" =~ ^[0-9]+$ ]] && [ "$sn" -le "$user_count" ] && [ "$sn" -gt 0 ]; then
            local index=$((sn - 1))
            TO_DELETE+=("${USER_LIST[$index]}")
        fi
    done

    if [ ${#TO_DELETE[@]} -eq 0 ]; then
        echo -e "\n${RED}[-] Invalid selection.${NC}"; pause; return
    fi

    echo -e "\n${ORANGE}[*] Deleting ${#TO_DELETE[@]} account(s)...${NC}"
    for target in "${TO_DELETE[@]}"; do
        /opt/janabitech/bin/janabitech user del "$target" > /dev/null 2>&1
        echo -e "  - Deleted: ${RED}${target}${NC}"
    done
    pause
}


execute_list_users() {
    clear
    echo -e "${CYAN}=== SSH MEMBERS LIST ===${NC}"
    draw_line
    printf "${BOLD}%-5s | %-15s | %-15s | %-10s${NC}\n" "S/N" "USERNAME" "EXPIRES ON" "STATUS"
    draw_line
    
    local i=1
    sqlite3 -separator '|' "$DB_PATH" "SELECT username, expiry_date, status FROM users;" | while read -r line; do
        local uname=$(echo "$line" | cut -d'|' -f1)
        local exp=$(echo "$line" | cut -d'|' -f2 | cut -d' ' -f1)
        local status=$(echo "$line" | cut -d'|' -f3)
        
        if [ "$status" == "ACTIVE" ]; then status_color="${GREEN}"; else status_color="${RED}"; fi
        printf "${GREEN}%-5s${NC} | ${CYAN}%-15s${NC} | ${ORANGE}%-15s${NC} | ${status_color}%-10s${NC}\n" "$i" "$uname" "$exp" "$status"
        ((i++))
    done
    draw_line
    pause
}

execute_online_users() {
    clear
    echo -e "${CYAN}=== ACTIVE CONNECTIONS ===${NC}"
    draw_line
    printf "${BOLD}%-20s | %-15s${NC}\n" "USERNAME" "ACTIVE DEVICES"
    draw_line
    
    local raw_data=$(/opt/janabitech/bin/janabitech sys online)
    
    if [[ "$raw_data" == *"No active"* ]] || [[ "$raw_data" == *"starting"* ]]; then
        echo -e "${ORANGE}$raw_data${NC}"
    else
        echo "$raw_data" | while IFS='|' read -r uname count; do
            # Add a red warning if count is high
            if [ "$count" -ge 3 ]; then
                printf "${GREEN}%-20s${NC} | ${RED}%-15s${NC}\n" "$uname" "$count"
            else
                printf "${GREEN}%-20s${NC} | ${CYAN}%-15s${NC}\n" "$uname" "$count"
            fi
        done
    fi
    draw_line
    pause
}

execute_user_details() {
    clear
    echo -e "${CYAN}=== PRINT USER DETAILS ===${NC}"
    select_user_from_list
    if [[ -z "$FINAL_USERNAME" ]]; then return; fi
    
    # Format the absolute expiry date fetched from the list selection
    local EXP_DATE_FORMATTED=$(date -d "$FINAL_EXPIRY" +"%B %d, %Y" 2>/dev/null || echo "$FINAL_EXPIRY")
    local USERNAME="$FINAL_USERNAME"
    local PASSWORD="[HIDDEN]" # Security constraint: PAM handles auth, DB stores metadata
    
    # Fetch dynamic server data
    local IP_ADDR=$(curl -sS ipv4.icanhazip.com)
    local PUB_KEY=$(cat /opt/janabitech/core/keys/dnstt.pub 2>/dev/null || echo "Missing Key")

    local MAX_LOGINS=$(sqlite3 "$DB_PATH" "SELECT max_logins FROM users WHERE username='$FINAL_USERNAME';" 2>/dev/null || echo "2")
    local LOGIN_DISP="$MAX_LOGINS"
    if [ "$MAX_LOGINS" -eq 0 ]; then LOGIN_DISP="Unlimited"; fi

    source /opt/janabitech/core/server_geo.env 2>/dev/null
    local COUNTRY="${SERVER_COUNTRY:-Unknown}"
    local ISP="${SERVER_ISP:-Unknown}"

    clear
    echo -e "${GREEN}User details fetched successfully${NC}       "
    
    echo -e "======== ACCOUNT DETAILS ========"
    echo -e "Username      : ${USERNAME}"
    echo -e "Password      : ${RED}${PASSWORD}${NC} (Encrypted by OS)"
    echo -e "Expires On    : ${EXP_DATE_FORMATTED}"
    echo -e "Max Limit     : ${LOGIN_DISP}"
    echo -e "Public IP     : ${IP_ADDR} (${COUNTRY})"
    echo -e "Host          : ${PRIMARY_DOMAIN}"
    echo -e "ISP Provider  : ${ISP}"
    echo -e "========================================"
    echo -e "Nameserver    : ${NS_DOMAIN}"
    echo -e "PubKey        : ${PUB_KEY}"
    echo -e "DNS Resolver  : 1.1.1.1 / 8.8.8.8\n"
    
    echo -e "SSH WS(S)     : ${PORT_WS_HTTP:-80} / ${PORT_WS_HTTPS:-443}"
    echo -e "SOCKS5        : ${PORT_SOCKS:-1080}"
    echo -e "Custom SSH    : 8880"
    echo -e "Dropbear      : ${PORT_DROPBEAR:-109}, ${PORT_DROPBEAR_ALT:-143}"
    echo -e "SSL/TLS       : 447, 777"
    echo -e "UDPGW         : 7300"
    echo -e "========================================"
    echo -e "SSH-80        : ${PRIMARY_DOMAIN}:${PORT_WS_HTTP:-80}@${USERNAME}:${PASSWORD}"
    echo -e "SSH-443       : ${PRIMARY_DOMAIN}:${PORT_WS_HTTPS:-443}@${USERNAME}:${PASSWORD}"
    echo -e "SOCKS5        : ${PRIMARY_DOMAIN}:${PORT_SOCKS:-1080}:${USERNAME}:${PASSWORD}"
    echo -e "SSH-8880      : ${PRIMARY_DOMAIN}:8880@${USERNAME}:${PASSWORD}"
    echo -e "========================================"
    echo -e "WSS Payload"
    echo -e "GET wss://bug.com [protocol][crlf]Host: ${PRIMARY_DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]\n"
    echo -e "WS Payload"
    echo -e "GET / HTTP/1.1[crlf]Host: ${PRIMARY_DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]\n"
    echo -e "Custom Payload"
    echo -e "GET http://${PRIMARY_DOMAIN}:8880 HTTP/1.1[crlf]Host: [SNI_BUG_HOST][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
    echo -e "========================================"
    echo -e "     NO SPAM | NO DDOS | NO TORRENT"
    echo -e "========================================"
    
    pause
}

# --- Helper function for Interactive Lists ---
select_user_from_list() {
    local user_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users;" 2>/dev/null || echo "0")
    if [ "$user_count" -eq 0 ]; then
        echo -e "\n${ORANGE}[!] No users found in the database.${NC}"
        sleep 2; FINAL_USERNAME=""; return
    fi

    draw_line
    printf "${BOLD}%-5s | %-15s | %-15s${NC}\n" "S/N" "USERNAME" "EXPIRES ON"
    draw_line
    
    mapfile -t USER_LIST < <(sqlite3 -separator '|' "$DB_PATH" "SELECT username, expiry_date FROM users;")
    local i=1
    for user_data in "${USER_LIST[@]}"; do
        local uname=$(echo "$user_data" | cut -d'|' -f1)
        local exp=$(echo "$user_data" | cut -d'|' -f2 | cut -d' ' -f1)
        printf "${GREEN}%-5s${NC} | ${CYAN}%-15s${NC} | ${ORANGE}%-15s${NC}\n" "$i" "$uname" "$exp"
        ((i++))
    done
    draw_line
    echo -e "${ORANGE}[0] Cancel${NC}\n"

    read -p "Select S/N or type Username: " TARGET_USER
    if [[ "$TARGET_USER" == "0" || -z "$TARGET_USER" ]]; then FINAL_USERNAME=""; return; fi

    FINAL_USERNAME=""
    if [[ "$TARGET_USER" =~ ^[0-9]+$ ]] && [ "$TARGET_USER" -le "${#USER_LIST[@]}" ] && [ "$TARGET_USER" -gt 0 ]; then
        local index=$((TARGET_USER - 1))
        FINAL_USERNAME=$(echo "${USER_LIST[$index]}" | cut -d'|' -f1)
        FINAL_EXPIRY=$(echo "${USER_LIST[$index]}" | cut -d'|' -f2)
    else
        for user_data in "${USER_LIST[@]}"; do
            local uname=$(echo "$user_data" | cut -d'|' -f1)
            if [[ "$uname" == "$TARGET_USER" ]]; then
                FINAL_USERNAME="$uname"
                FINAL_EXPIRY=$(echo "$user_data" | cut -d'|' -f2)
                break
            fi
        done
    fi

    if [[ -z "$FINAL_USERNAME" ]]; then
        echo -e "\n${RED}[-] Invalid selection.${NC}"; sleep 1; FINAL_USERNAME=""
    fi
}

print_user_receipt() {
    local USERNAME="$1"
    local PASSWORD="$2"
    local TIME_VAL="$3"
    local TIME_TYPE="$4"
    local MAX_LOGINS="${5:-2}" 
    local BW_LIMIT="${6:-0}"
    
    IP_ADDR=$(curl -sS ipv4.icanhazip.com)
    PUB_KEY=$(cat /opt/janabitech/core/keys/dnstt.pub 2>/dev/null || echo "Missing Key")
    
    source /opt/janabitech/core/server_geo.env 2>/dev/null
    local COUNTRY="${SERVER_COUNTRY:-Unknown}"
    local ISP="${SERVER_ISP:-Unknown}"
    
    local EXP_LABEL="Expires On  "
    local HEADER_MSG="Account provisioned successfully!"
    local FOOTER_MSG=""

    if [ "$TIME_TYPE" == "hours" ]; then
        EXP_DATE_FORMATTED=$(date -d "+${TIME_VAL} hours" +"%B %d, %Y - %H:%M")
        EXP_LABEL="Valid Until "
        HEADER_MSG="Trial account provisioned successfully!"
        FOOTER_MSG="\nOnce the trial expires, the account will be deleted automatically."
    else
        EXP_DATE_FORMATTED=$(date -d "+${TIME_VAL} days" +"%B %d, %Y")
    fi

    local LOGIN_DISP="$MAX_LOGINS"
    if [ "$MAX_LOGINS" -eq 0 ]; then LOGIN_DISP="Unlimited"; fi

    local BW_DISP="${BW_LIMIT} GB"
    if [ "$BW_LIMIT" -eq 0 ]; then BW_DISP="Unlimited"; fi

    clear
    echo -e "${GREEN}${HEADER_MSG}${NC}"
    echo -e "Copy the details below to your clipboard:\n"
    
    echo -e "======== ACCOUNT DETAILS ========"
    echo -e "Username      : ${USERNAME}"
    echo -e "Password      : ${PASSWORD}"
    echo -e "Limit         : ${LOGIN_DISP} Device(s)"
    echo -e "Data Limit    : ${BW_DISP}"
    if [ "$TIME_TYPE" == "hours" ]; then
        echo -e "Duration      : ${TIME_VAL} hours"
    fi
    echo -e "${EXP_LABEL}  : ${EXP_DATE_FORMATTED}"
    echo -e "Max Limit     : ${LOGIN_DISP}"
    echo -e "Public IP     : ${IP_ADDR} (${COUNTRY})"
    echo -e "Host          : ${PRIMARY_DOMAIN}"
    echo -e "ISP Provider  : ${ISP}"
    echo -e "========================================"
    echo -e "Nameserver    : ${NS_DOMAIN}"
    echo -e "PubKey        : ${PUB_KEY}"
    echo -e "DNS Resolver  : 1.1.1.1 / 8.8.8.8\n"
    
    echo -e "SSH WS(S)     : ${PORT_WS_HTTP:-80} / ${PORT_WS_HTTPS:-443}"
    echo -e "SOCKS5        : ${PORT_SOCKS:-1080}"
    echo -e "Custom SSH    : 8880"
    echo -e "Dropbear      : ${PORT_DROPBEAR:-109}, ${PORT_DROPBEAR_ALT:-143}"
    echo -e "SSL/TLS       : 447, 777"
    echo -e "UDPGW         : 7300"
    echo -e "========================================"
    echo -e "SSH-80        : ${PRIMARY_DOMAIN}:${PORT_WS_HTTP:-80}@${USERNAME}:${PASSWORD}"
    echo -e "SSH-443       : ${PRIMARY_DOMAIN}:${PORT_WS_HTTPS:-443}@${USERNAME}:${PASSWORD}"
    echo -e "SOCKS5        : ${PRIMARY_DOMAIN}:${PORT_SOCKS:-1080}:${USERNAME}:${PASSWORD}"
    echo -e "SSH-8880      : ${PRIMARY_DOMAIN}:8880@${USERNAME}:${PASSWORD}"
    echo -e "========================================"
    echo -e "WSS Payload"
    echo -e "GET wss://bug.com [protocol][crlf]Host: ${PRIMARY_DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]\n"
    echo -e "WS Payload"
    echo -e "GET / HTTP/1.1[crlf]Host: ${PRIMARY_DOMAIN}[crlf]Upgrade: websocket[crlf][crlf]\n"
    echo -e "Custom Payload"
    echo -e "GET http://${PRIMARY_DOMAIN}:8880 HTTP/1.1[crlf]Host: [SNI_BUG_HOST][crlf]Upgrade: websocket[crlf]Connection: Upgrade[crlf][crlf]"
    echo -e "========================================"
    echo -e "     NO SPAM | NO DDOS | NO TORRENT"
    echo -e "========================================"
    if [[ -n "$FOOTER_MSG" ]]; then echo -e "${ORANGE}${FOOTER_MSG}${NC}"; fi
    
    pause
}

execute_locked_users() {
    clear
    echo -e "${CYAN}=== LOCKED/BANNED USERS ===${NC}"
    
    local locked_count=$(sqlite3 "$DB_PATH" "SELECT COUNT(*) FROM users WHERE status='LOCKED';" 2>/dev/null || echo "0")
    if [ "$locked_count" -eq 0 ]; then
        echo -e "\n${GREEN}[+] No locked users found.${NC}"
        pause
        return
    fi

    draw_line
    printf "${BOLD}%-5s | %-15s | %-15s${NC}\n" "S/N" "USERNAME" "EXPIRY DATE"
    draw_line
    
    mapfile -t USER_LIST < <(sqlite3 -separator '|' "$DB_PATH" "SELECT username, expiry_date FROM users WHERE status='LOCKED';")
    local i=1
    for user_data in "${USER_LIST[@]}"; do
        local uname=$(echo "$user_data" | cut -d'|' -f1)
        local exp=$(echo "$user_data" | cut -d'|' -f2 | cut -d' ' -f1)
        printf "${RED}%-5s${NC} | ${CYAN}%-15s${NC} | ${ORANGE}%-15s${NC}\n" "$i" "$uname" "$exp"
        ((i++))
    done
    draw_line
    echo -e "${ORANGE}[0] Cancel${NC}\n"

    read -p " Select S/N to UNLOCK user: " TARGET_USER
    if [[ "$TARGET_USER" == "0" || -z "$TARGET_USER" ]]; then return; fi

    local FINAL_USERNAME=""
    if [[ "$TARGET_USER" =~ ^[0-9]+$ ]] && [ "$TARGET_USER" -le "${#USER_LIST[@]}" ] && [ "$TARGET_USER" -gt 0 ]; then
        local index=$((TARGET_USER - 1))
        FINAL_USERNAME=$(echo "${USER_LIST[$index]}" | cut -d'|' -f1)
    fi

    if [[ -z "$FINAL_USERNAME" ]]; then
        echo -e "\n${RED}[-] Invalid selection.${NC}"; sleep 1; return
    fi

    echo -e "\n${GREEN}Unlocking user: ${FINAL_USERNAME}...${NC}"
    usermod -U "$FINAL_USERNAME" 2>/dev/null
    sqlite3 "$DB_PATH" "UPDATE users SET status='ACTIVE' WHERE username='$FINAL_USERNAME';" 2>/dev/null
    echo -e "${GREEN}[+] User unlocked successfully!${NC}"
    pause
}

# ==========================================================
# [02] DOMAIN & SSL
# ==========================================================
menu_domain_ssl() {
    while true; do
        clear
        # Re-source config inside the loop so the UI updates dynamically if a domain changes
        source /opt/janabitech/core/janabitech.conf
        local PUB_KEY=$(cat /opt/janabitech/core/keys/dnstt.pub 2>/dev/null || echo "Missing Key")
        
        draw_line
        echo -e "                   ${BOLD}DOMAIN & SSL${NC}                     "
        draw_line
        echo -e "  Current Host : ${GREEN}${PRIMARY_DOMAIN}${NC}"
        echo -e "  Current NS   : ${CYAN}${NS_DOMAIN}${NC}"
        echo -e "  SlowDNS Pub  : ${ORANGE}${PUB_KEY}${NC}"
        draw_line
        echo -e "  ${CYAN}[01]${NC} Change Host Domain"
        echo -e "  ${CYAN}[02]${NC} Change NS Domain"
        echo -e "  ${CYAN}[03]${NC} Renew SSL Certificate (Let's Encrypt)"
        echo -e "  ${CYAN}[04]${NC} View Certificate Status"
        echo -e "  ${CYAN}[05]${NC} Generate New SlowDNS Key"
        echo -e ""
        echo -e "  ${RED}[00]${NC} Return to Main Menu"
        draw_line
        read -p " Select Option : " opt

        case $opt in
            1) 
                echo -e "\n${CYAN}Current Domain: ${PRIMARY_DOMAIN}${NC}"
                read -p "Enter New Host Domain: " new_host
                if [[ -n "$new_host" ]]; then
                    /opt/janabitech/bin/janabitech config host "$new_host"
                    echo ""
                    read -p "Renew Let's Encrypt SSL for $new_host now? (y/n): " do_ssl
                    if [[ "$do_ssl" =~ ^[Yy] ]]; then
                        echo -e "\n${ORANGE}[*] Requesting Certificate... this takes 30-60 seconds...${NC}"
                        /opt/janabitech/bin/janabitech cert renew "$new_host"
                    fi
                fi
                pause ;;
            2) 
                echo -e "\n${CYAN}Current NS Domain: ${NS_DOMAIN}${NC}"
                read -p "Enter New NS Domain: " new_ns
                if [[ -n "$new_ns" ]]; then
                    /opt/janabitech/bin/janabitech config ns "$new_ns"
                fi
                pause ;;
            3) 
                echo -e "\n${ORANGE}[*] Requesting Let's Encrypt Certificate. Services will temporarily pause...${NC}"
                /opt/janabitech/bin/janabitech cert renew "$PRIMARY_DOMAIN"
                pause ;;
            4) 
                clear
                echo -e "${CYAN}=== ACME.SH CERTIFICATE STATUS ===${NC}"
                /root/.acme.sh/acme.sh --list 2>/dev/null || echo -e "${RED}acme.sh is not installed yet.${NC}"
                pause ;;
            5) 
                echo -e "\n${ORANGE}[*] Warning: Generating a new key will break existing SlowDNS clients.${NC}"
                read -p "Are you sure? (y/n): " confirm_dnstt
                if [[ "$confirm_dnstt" =~ ^[Yy] ]]; then
                    /opt/janabitech/bin/janabitech dnstt renew
                fi
                pause ;;
            0) return ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# ==========================================================
# [03] RUNNING SERVICES
# ==========================================================
menu_services() {
    while true; do
        clear
        draw_line
        echo -e "                 ${BOLD}RUNNING SERVICES${NC}                   "
        draw_line
        echo -e "  ${CYAN}OpenSSH           :${NC} 22"
        echo -e "  ${CYAN}Dropbear          :${NC} 109, 143"
        echo -e "  ${CYAN}Stunnel4          :${NC} 447, 777"
        echo -e "  ${CYAN}SSH-WS (HTTP)     :${NC} 80"
        echo -e "  ${CYAN}SSH-WSS (HTTPS)   :${NC} 443"
        echo -e "  ${CYAN}Custom SSH (HTTP) :${NC} 8880"
        echo -e "  ${CYAN}SlowDNS (DNSTT)   :${NC} 53, 5300"
        echo -e "  ${CYAN}UDP Custom        :${NC} 1-65535"
        echo -e "  ${CYAN}SOCKS5 Proxy      :${NC} 1080"
        draw_line
        echo -e "  ${CYAN}[01]${NC} Restart All Services"
        echo -e "  ${CYAN}[02]${NC} Restart Dropbear"
        echo -e "  ${CYAN}[03]${NC} Restart WebSocket Proxy"
        echo -e "  ${CYAN}[04]${NC} Restart Stunnel"
        echo -e "  ${CYAN}[05]${NC} Restart DNSTT"
        echo -e ""
        echo -e "  ${RED}[00]${NC} Return to Main Menu"
        draw_line
        read -p " Select Option : " opt

        case $opt in
            1) /opt/janabitech/bin/janabitech service restart all; pause ;;
            2) /opt/janabitech/bin/janabitech service restart dropbear; pause ;;
            3) /opt/janabitech/bin/janabitech service restart janabitech-ws; pause ;;
            4) /opt/janabitech/bin/janabitech service restart stunnel4; pause ;;
            5) /opt/janabitech/bin/janabitech service restart janabitech-dnstt; pause ;;
            0) return ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# ==========================================================
# [04] MONITORING
# ==========================================================
format_bytes() {
    local bytes=$1
    if [[ -z "$bytes" || "$bytes" -eq 0 ]]; then
        echo "0.00 MB"
    elif [[ $bytes -ge 1073741824 ]]; then
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1073741824}") GB"
    else
        echo "$(awk "BEGIN {printf \"%.2f\", $bytes/1048576}") MB"
    fi
}

menu_monitoring() {
    while true; do
        clear
        draw_line
        echo -e "                    ${BOLD}MONITORING${NC}                      "
        draw_line
        echo -e "  ${CYAN}[01]${NC} Current Bandwidth Usage (All Users)"
        echo -e "  ${CYAN}[02]${NC} Top Users (Leaderboard)"
        echo -e "  ${CYAN}[03]${NC} Connection Logs"
        echo -e "  ${CYAN}[04]${NC} Failed Login Attempts"
        echo -e "  ${CYAN}[05]${NC} System Resource Usage"
        echo -e ""
        echo -e "  ${RED}[00]${NC} Return to Main Menu"
        draw_line
        read -p " Select Option : " opt

        case $opt in
            1) 
                clear
                echo -e "${CYAN}=== TOTAL BANDWIDTH USAGE ===${NC}"
                draw_line
                printf "${BOLD}%-5s | %-15s | %-15s${NC}\n" "S/N" "USERNAME" "DATA USED"
                draw_line
                
                local i=1
                sqlite3 -separator '|' "$DB_PATH" "SELECT username, data_usage FROM users ORDER BY username ASC;" | while read -r line; do
                    local uname=$(echo "$line" | cut -d'|' -f1)
                    local bytes=$(echo "$line" | cut -d'|' -f2)
                    local formatted=$(format_bytes "$bytes")
                    printf "${GREEN}%-5s${NC} | ${CYAN}%-15s${NC} | ${ORANGE}%-15s${NC}\n" "$i" "$uname" "$formatted"
                    ((i++))
                done
                draw_line
                pause ;;
            2) 
                clear
                echo -e "${CYAN}=== TOP USERS (DATA LEADERBOARD) ===${NC}"
                draw_line
                printf "${BOLD}%-5s | %-15s | %-15s${NC}\n" "RANK" "USERNAME" "DATA USED"
                draw_line
                
                local rank=1
                # Sort by data_usage descending, limit to top 80
                sqlite3 -separator '|' "$DB_PATH" "SELECT username, data_usage FROM users WHERE data_usage > 0 ORDER BY data_usage DESC LIMIT 80;" | while read -r line; do
                    local uname=$(echo "$line" | cut -d'|' -f1)
                    local bytes=$(echo "$line" | cut -d'|' -f2)
                    local formatted=$(format_bytes "$bytes")
                    
                    # Highlight the #1 user in red/gold
                    if [ "$rank" -eq 1 ]; then
                        printf "${RED}%-5s${NC} | ${GREEN}%-15s${NC} | ${ORANGE}%-15s${NC}\n" "#$rank" "$uname" "$formatted"
                    else
                        printf "${GREEN}%-5s${NC} | ${CYAN}%-15s${NC} | ${ORANGE}%-15s${NC}\n" "#$rank" "$uname" "$formatted"
                    fi
                    ((rank++))
                done
                if [ "$rank" -eq 1 ]; then
                    echo -e "  ${ORANGE}No data usage recorded yet.${NC}"
                fi
                draw_line
                pause ;;
            3) tail -n 50 /opt/janabitech/logs/janabitech.log; pause ;;
            4) grep "Failed password" /var/log/auth.log | tail -n 20; pause ;;
            5) 
               if [ -x "/opt/janabitech/bin/btop" ]; then
                   /opt/janabitech/bin/btop
               else
                   htop || top
               fi
               pause ;;
            0) return ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# ==========================================================
# [05] SETTINGS
# ==========================================================
menu_settings() {
    while true; do
        clear
        draw_line
        echo -e "                     ${BOLD}SETTINGS${NC}                       "
        draw_line
        echo -e "  ${CYAN}[01]${NC} Set Auto Reboot"
        echo -e "  ${CYAN}[02]${NC} Change SSH Banner"
        echo -e "  ${CYAN}[03]${NC} Speedtest Server"
        echo -e "  ${CYAN}[04]${NC} Uninstall Script"
        echo -e "  ${CYAN}[05]${NC} Refresh Server Geo-Data"
        echo -e "  ${CYAN}[06]${NC} Deploy Fail2Ban Firewall"
        echo -e ""
        echo -e "  ${RED}[00]${NC} Return to Main Menu"
        draw_line
        read -p " Select Option : " opt

        case $opt in
            1) 
                echo -e "\n${CYAN}Auto Reboot Schedule${NC}"
                echo "1. Every 6 Hours"
                echo "2. Every 12 Hours"
                echo "3. Every 24 Hours"
                echo "0. Turn Off Auto Reboot"
                read -p "Select Option: " rb_opt
                case $rb_opt in
                    1) /opt/janabitech/bin/janabitech sys autoreboot 6 ;;
                    2) /opt/janabitech/bin/janabitech sys autoreboot 12 ;;
                    3) /opt/janabitech/bin/janabitech sys autoreboot 24 ;;
                    0) /opt/janabitech/bin/janabitech sys autoreboot 0 ;;
                    *) echo -e "${RED}Invalid selection.${NC}" ;;
                esac
                pause ;;
            2) 
                clear
                echo -e "\n${CYAN}=== UPDATE SSH BANNER ===${NC}"
                echo -e "${ORANGE}Opening /etc/issue.net in nano editor...${NC}"
                echo -e "Instructions:"
                echo -e "  1. Edit your HTML code."
                echo -e "  2. Press ${GREEN}CTRL + O${NC} then ${GREEN}ENTER${NC} to save."
                echo -e "  3. Press ${GREEN}CTRL + X${NC} to exit."
                echo ""
                read -n 1 -s -r -p "Press any key to open the editor..."
                
                # Call the API which now handles launching nano natively
                /opt/janabitech/bin/janabitech sys banner
                
                pause ;;
            3) 
               clear
               echo -e "${CYAN}Initializing Server Speedtest...${NC}\n"
               if [ -x "/opt/janabitech/bin/speedtest" ]; then
                   /opt/janabitech/bin/speedtest --accept-license --accept-gdpr
               else
                   echo -e "${RED}[!] Ookla Speedtest binary not found. Please re-run the installer.${NC}"
               fi
               pause ;;
            4) 
                clear
                echo -e "${RED}${BOLD}======================================================${NC}"
                echo -e "${RED}${BOLD}  DANGER: COMPLETELY UNINSTALL JANABI PLATFORM     ${NC}"
                echo -e "${RED}${BOLD}======================================================${NC}"
                echo -e "This action will:"
                echo -e "  - Delete all VPN accounts & databases"
                echo -e "  - Remove all Sidecars, Ports, and Routing rules"
                echo -e "  - Wipe the /opt/janabitech directory entirely\n"
                
                read -p "Are you absolutely sure? (Type 'YES' to confirm): " confirm_wipe
                if [ "$confirm_wipe" == "YES" ]; then
                    echo -e "\n${ORANGE}[*] Wiping infrastructure...${NC}"
                    /opt/janabitech/bin/janabitech sys uninstall
                    echo -e "${GREEN}System is clean. Exiting...${NC}"
                    sleep 2
                    exit 0
                else
                    echo -e "\n${GREEN}Uninstallation aborted.${NC}"
                    pause
                fi
                ;;
            5)
                echo -e "\n${CYAN}[*] Flushing Server Geo-Data cache...${NC}"
                rm -f /opt/janabitech/core/server_geo.env
                fetch_server_geo
                echo -e "${GREEN}[+] Geographic data successfully refreshed!${NC}"
                pause ;;
            6)
                clear
                echo -e "\n${CYAN}=== DEPLOY FAIL2BAN FIREWALL ===${NC}"
                echo -e "${ORANGE}This will automatically install and configure Fail2Ban${NC}"
                echo -e "to instantly block bots that fail 3 login attempts.\n"
                read -p "Proceed with deployment? (y/n): " confirm_f2b
                if [[ "$confirm_f2b" =~ ^[Yy] ]]; then
                    echo ""
                    /opt/janabitech/bin/janabitech sys fail2ban
                fi
                pause ;;
            0) return ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

menu_backup_restore() {
    while true; do
        clear
        draw_line
        echo -e "                 ${BOLD}BACKUP & RESTORE${NC}                   "
        draw_line
        echo -e "  ${CYAN}[01]${NC} Create System Backup"
        echo -e "  ${CYAN}[02]${NC} Restore from Backup"
        echo -e ""
        echo -e "  ${RED}[00]${NC} Return to Main Menu"
        draw_line
        read -p " Select Option : " opt

        case $opt in
            1)
                echo -e "\n${CYAN}Creating backup archive...${NC}"
                /opt/janabitech/bin/janabitech sys backup
                pause
                ;;
            2)
                clear
                echo -e "${CYAN}=== RESTORE SYSTEM BACKUP ===${NC}"
                local backup_dir="/opt/janabitech/backups"
                
                # Ensure directory exists and is writable for SFTP uploads
                if [ ! -d "$backup_dir" ]; then
                    mkdir -p "$backup_dir"
                    chmod 777 "$backup_dir"
                fi
                
                # Check if directory is empty
                if [ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]; then
                    echo -e "\n${ORANGE}[!] No backups found in $backup_dir.${NC}"
                    echo -e "${CYAN}Tip: Upload your .tar.gz.enc backup file to this folder via SFTP.${NC}"
                    pause
                    continue
                fi

                echo -e "Available Archives:\n"
                # Read all encrypted backup files into an array, sorted by newest first
                mapfile -t BACKUP_LIST < <(ls -1t "$backup_dir"/*.tar.gz.enc 2>/dev/null)

                local i=1
                for b_file in "${BACKUP_LIST[@]}"; do
                    local b_name=$(basename "$b_file")
                    local b_size=$(du -h "$b_file" | cut -f1)
                    local b_date=$(date -r "$b_file" +"%Y-%m-%d %H:%M:%S")
                    printf "  ${GREEN}[%02d]${NC} %-35s | %-5s | %-20s\n" "$i" "$b_name" "$b_size" "$b_date"
                    ((i++))
                done
                echo -e "\n  ${RED}[00]${NC} Cancel"

                read -p " Select Backup to Restore (S/N): " sel_idx
                if [[ "$sel_idx" == "0" || -z "$sel_idx" ]]; then continue; fi

                # Validate input is a number within bounds
                if [[ "$sel_idx" =~ ^[0-9]+$ ]] && [ "$sel_idx" -le "${#BACKUP_LIST[@]}" ] && [ "$sel_idx" -gt 0 ]; then
                    local target_file="${BACKUP_LIST[$((sel_idx-1))]}"
                    
                    echo -e "\n${RED}${BOLD}WARNING: Restoring will instantly overwrite your current users,${NC}"
                    echo -e "${RED}${BOLD}domains, TLS certificates, and SlowDNS keys!${NC}"
                    read -p "Are you absolutely sure? (Type 'YES' to confirm): " confirm_res
                    
                    if [ "$confirm_res" == "YES" ]; then
                        echo -e "\n${ORANGE}[*] Restoring system state and rebooting daemons...${NC}"
                        /opt/janabitech/bin/janabitech sys restore "$target_file"
                        echo -e "${GREEN}[+] Restore complete! System state reverted successfully.${NC}"
                    else
                        echo -e "\n${GREEN}Restore aborted.${NC}"
                    fi
                else
                    echo -e "\n${RED}Invalid selection.${NC}"
                fi
                pause
                ;;
            0) return ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# ==========================================================
# MAIN DASHBOARD LOOP
# ==========================================================
show_dashboard() {
    while true; do
        clear
        get_system_stats
        get_db_stats

        draw_top
        echo -e "${CYAN}│${NC} ${BOLD}${GREEN}             JANABI DASHBOARD             ${NC} ${CYAN}│${NC}"
        draw_mid
        echo -e "  ${ORANGE}✦ Server IP${NC}       : ${GREEN}${SERVER_IP}${NC} ${CYAN}(${SERVER_COUNTRY})${NC}"
        echo -e "  ${ORANGE}✦ ISP${NC}             : ${CYAN}${SERVER_ISP}${NC}"
        echo -e "  ${ORANGE}✦ Server Uptime${NC}   : ${GREEN}${UPTIME}${NC}"
        echo -e "  ${ORANGE}✦ Operating Sys${NC}   : ${CYAN}${OS_INFO}${NC}"
        echo -e "  ${ORANGE}✦ RAM / CPU Load${NC}  : ${GREEN}${RAM_USED}MB / ${RAM_TOTAL}MB${NC}  |  ${CYAN}${CPU_USAGE}${NC}"
        echo -e "  ${ORANGE}✦ Primary Domain${NC}  : ${GREEN}${PRIMARY_DOMAIN}${NC}"
        draw_mid
        
        printf "  ${CYAN}WS-Proxy: %b   Stunnel : %b   Dropbear: %b${NC}\n" "$(check_service janabitech-ws)" "$(check_service stunnel4)" "$(check_service dropbear)"
        printf "  ${CYAN}Dante   : %b   UDP Cust: %b   DNSTT   : %b${NC}\n" "$(check_service danted)" "$(check_service janabitech-udp-custom)" "$(check_service janabitech-dnstt)"
        printf "  ${CYAN}Monitor : %b${NC}\n" "$(check_service janabitech-monitor)"
        echo -e ""
        echo -e "  ${ORANGE}Data Used Today${NC}   : ${GREEN}${BW_TODAY}${NC}"
        echo -e "  ${ORANGE}Data Used Month${NC}   : ${CYAN}${BW_MONTH}${NC}"
        draw_mid
        
        echo -e "  Active Users : ${GREEN}${ACTIVE_USERS}${NC} / ${TOTAL_USERS}    Expired : ${RED}${EXPIRED_USERS}${NC}"
        draw_mid
        
        echo -e "  ${CYAN}[01]${NC} SSH PANEL            ${CYAN}[02]${NC} DOMAIN & SSL"
        echo -e "  ${CYAN}[03]${NC} RUNNING SERVICES     ${CYAN}[04]${NC} MONITORING"
        echo -e "  ${CYAN}[05]${NC} SETTINGS             ${CYAN}[06]${NC} BACKUP & RESTORE"
        echo -e "  ${CYAN}[07]${NC} UPDATE SCRIPT        ${CYAN}[08]${NC} REBOOT"
        echo -e ""
        echo -e "  ${RED}[00]${NC} EXIT"
        draw_bot
        read -p " Select Option : " opt

        case $opt in
            1) menu_ssh_panel ;;
            2) menu_domain_ssl ;;
            3) menu_services ;;
            4) menu_monitoring ;;
            5) menu_settings ;;
            6) menu_backup_restore ;;
            7) 
               clear
               echo -e "${CYAN}=== UPDATE JANABI PLATFORM ===${NC}"
               echo -e "${ORANGE}This will fetch the latest core files from GitHub.${NC}"
               echo -e "Your users, database, domains, and configurations will ${GREEN}NOT${NC} be affected.\n"
               
               read -p "Proceed with update? (y/n): " confirm_update
               if [[ "$confirm_update" =~ ^[Yy] ]]; then
                   echo ""
                   /opt/janabitech/bin/janabitech sys update
                   pause
               fi
               ;;
            8) 
               read -p "Are you sure you want to reboot the server? (y/n): " confirm
               if [[ "$confirm" =~ ^[Yy] ]]; then reboot; fi
               ;;
            0) clear; exit 0 ;;
            *) echo -e "${RED}Invalid option${NC}"; sleep 1 ;;
        esac
    done
}

# Boot the HUD
show_dashboard
