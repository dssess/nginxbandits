#!/bin/bash

BASE_DIR="/opt/nginxbandits"
CONFIG="${BASE_DIR}/core/nginxbandits.conf"
LOG_DIR="${BASE_DIR}/logs"
DB_PATH="${BASE_DIR}/core/database.db"

[ -f "$CONFIG" ] && source "$CONFIG"

mkdir -p "$LOG_DIR" 2>/dev/null || true

log_event() {
    local level="$1"
    local message="$2"
    local timestamp
    timestamp="$(date '+%Y-%m-%d %H:%M:%S')"

    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message" \
        >> "${LOG_DIR}/nginxbandits.log" 2>/dev/null || true

    printf '[%s] [%s] %s\n' "$timestamp" "$level" "$message"
}

check_root() {
    if [ "${EUID}" -ne 0 ]; then
        echo "[ERROR] NginxBandits requires root privileges."
        return 1
    fi
    return 0
}

check_command() {
    command -v "$1" >/dev/null 2>&1
}

safe_create_dir() {
    local directory="$1"

    [ -z "$directory" ] && return 1

    if [ ! -d "$directory" ]; then
        mkdir -p "$directory" || return 1
    fi

    return 0
}

change_host_domain() {
    local new_domain="$1"

    if [ -z "$new_domain" ]; then
        log_event "ERROR" "Primary domain cannot be empty."
        return 1
    fi

    if [[ ! "$new_domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
        log_event "ERROR" "Invalid domain: $new_domain"
        return 1
    fi

    if [ ! -f "$CONFIG" ]; then
        log_event "ERROR" "Configuration file not found."
        return 1
    fi

    sed -i \
        "s|^PRIMARY_DOMAIN=.*|PRIMARY_DOMAIN=\"$new_domain\"|" \
        "$CONFIG"

    PRIMARY_DOMAIN="$new_domain"

    log_event "INFO" "Primary domain changed to $new_domain."
    return 0
}

change_ns_domain() {
    local new_domain="$1"

    if [ -z "$new_domain" ]; then
        log_event "ERROR" "Nameserver domain cannot be empty."
        return 1
    fi

    if [[ ! "$new_domain" =~ ^[A-Za-z0-9.-]+$ ]]; then
        log_event "ERROR" "Invalid nameserver domain: $new_domain"
        return 1
    fi

    if [ ! -f "$CONFIG" ]; then
        log_event "ERROR" "Configuration file not found."
        return 1
    fi

    sed -i \
        "s|^NS_DOMAIN=.*|NS_DOMAIN=\"$new_domain\"|" \
        "$CONFIG"

    NS_DOMAIN="$new_domain"

    if systemctl cat nginxbandits-dnstt >/dev/null 2>&1; then
        systemctl restart nginxbandits-dnstt >/dev/null 2>&1 || true
    elif systemctl cat janabitech-dnstt >/dev/null 2>&1; then
        systemctl restart janabitech-dnstt >/dev/null 2>&1 || true
    fi

    log_event "INFO" "Nameserver domain changed to $new_domain."
    return 0
}

renew_ssl_cert() {
    local domain="${1:-$PRIMARY_DOMAIN}"

    if [ -z "$domain" ]; then
        log_event "ERROR" "No SSL domain supplied."
        return 1
    fi

    local key_dir="${BASE_DIR}/core/keys"
    local cert="${key_dir}/fullchain.cer"
    local key="${key_dir}/private.key"
    local bundle="${key_dir}/stunnel.pem"

    safe_create_dir "$key_dir" || return 1

    if ! check_command openssl; then
        log_event "ERROR" "OpenSSL is not installed."
        return 1
    fi

    log_event "INFO" "Preparing TLS certificate for $domain."

    openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "$key" \
        -out "$cert" \
        -subj "/C=KE/O=NginxBandits/CN=$domain" \
        >/dev/null 2>&1 || {
            log_event "ERROR" "Certificate generation failed."
            return 1
        }

    cat "$cert" "$key" > "$bundle"

    chmod 600 "$key" "$cert" "$bundle"

    for service in stunnel4 janabitech-ws nginxbandits-ws; do
        if systemctl cat "$service" >/dev/null 2>&1; then
            systemctl restart "$service" >/dev/null 2>&1 || true
        fi
    done

    log_event "INFO" "TLS certificate refreshed for $domain."
    return 0
}

generate_dnstt_key() {
    local key_dir="${BASE_DIR}/core/keys"
    local private_key="${key_dir}/dnstt.key"
    local public_key="${key_dir}/dnstt.pub"

    safe_create_dir "$key_dir" || return 1

    if [ ! -x "${BASE_DIR}/bin/dnstt-server" ]; then
        log_event "ERROR" "DNSTT server binary not found."
        return 1
    fi

    "${BASE_DIR}/bin/dnstt-server" \
        -gen-key \
        -privkey-file "$private_key" \
        -pubkey-file "$public_key" || {
            log_event "ERROR" "DNSTT key generation failed."
            return 1
        }

    chmod 600 "$private_key"
    chmod 644 "$public_key"

    if systemctl cat nginxbandits-dnstt >/dev/null 2>&1; then
        systemctl restart nginxbandits-dnstt >/dev/null 2>&1 || true
    elif systemctl cat janabitech-dnstt >/dev/null 2>&1; then
        systemctl restart janabitech-dnstt >/dev/null 2>&1 || true
    fi

    log_event "INFO" "DNSTT keys regenerated."
    return 0
}

set_auto_reboot() {
    local hours="$1"

    if ! [[ "$hours" =~ ^[0-9]+$ ]]; then
        log_event "ERROR" "Invalid reboot interval."
        return 1
    fi

    crontab -l 2>/dev/null | \
        grep -vF "/sbin/reboot" | \
        crontab - 2>/dev/null || true

    if [ "$hours" -eq 0 ]; then
        log_event "INFO" "Automatic reboot disabled."
        return 0
    fi

    (
        crontab -l 2>/dev/null
        echo "0 */${hours} * * * /sbin/reboot"
    ) | crontab -

    log_event "INFO" "Automatic reboot configured every ${hours} hours."
    return 0
}

change_banner() {
    local banner="/etc/issue.net"

    if check_command nano; then
        nano "$banner"
    else
        ${EDITOR:-vi} "$banner"
    fi

    for service in dropbear ssh sshd; do
        if systemctl cat "$service" >/dev/null 2>&1; then
            systemctl restart "$service" >/dev/null 2>&1 || true
        fi
    done

    log_event "INFO" "SSH banner updated."
}

create_backup() {
    local backup_dir="${BASE_DIR}/backups"
    local timestamp
    local archive
    local temp_dir

    timestamp="$(date '+%Y%m%d-%H%M%S')"
    archive="${backup_dir}/nginxbandits-${timestamp}.tar.gz"
    temp_dir="$(mktemp -d)"

    safe_create_dir "$backup_dir" || return 1

    mkdir -p "$temp_dir/core" "$temp_dir/keys"

    [ -f "$DB_PATH" ] &&
        cp -a "$DB_PATH" "$temp_dir/core/database.db"

    [ -f "$CONFIG" ] &&
        cp -a "$CONFIG" "$temp_dir/core/nginxbandits.conf"

    if [ -d "${BASE_DIR}/core/keys" ]; then
        cp -a "${BASE_DIR}/core/keys/." "$temp_dir/keys/" 2>/dev/null || true
    fi

    tar -czf "$archive" -C "$temp_dir" . || {
        rm -rf "$temp_dir"
        return 1
    }

    chmod 600 "$archive"
    rm -rf "$temp_dir"

    log_event "INFO" "Backup created: $archive"
    echo "$archive"
    return 0
}

restore_backup() {
    local archive="$1"

    if [ -z "$archive" ] || [ ! -f "$archive" ]; then
        log_event "ERROR" "Backup archive not found."
        return 1
    fi

    local temp_dir
    temp_dir="$(mktemp -d)"

    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        rm -rf "$temp_dir"
        log_event "ERROR" "Invalid backup archive."
        return 1
    fi

    tar -xzf "$archive" -C "$temp_dir"

    if [ -f "$temp_dir/core/database.db" ]; then
        mkdir -p "$(dirname "$DB_PATH")"
        cp -a "$temp_dir/core/database.db" "$DB_PATH"
        chmod 600 "$DB_PATH"
    fi

    if [ -f "$temp_dir/core/nginxbandits.conf" ]; then
        cp -a "$temp_dir/core/nginxbandits.conf" "$CONFIG"
    fi

    if [ -d "$temp_dir/keys" ]; then
        mkdir -p "${BASE_DIR}/core/keys"
        cp -a "$temp_dir/keys/." "${BASE_DIR}/core/keys/"
        chmod 600 "${BASE_DIR}/core/keys/"* 2>/dev/null || true
    fi

    rm -rf "$temp_dir"

    log_event "INFO" "Backup restored successfully."
    return 0
}

install_fail2ban() {
    if ! check_command fail2ban-client; then
        log_event "INFO" "Installing Fail2Ban."

        DEBIAN_FRONTEND=noninteractive \
            apt-get update -y >/dev/null 2>&1

        DEBIAN_FRONTEND=noninteractive \
            apt-get install -y fail2ban >/dev/null 2>&1 || {
                log_event "ERROR" "Fail2Ban installation failed."
                return 1
            }
    fi

    systemctl enable fail2ban >/dev/null 2>&1 || true
    systemctl restart fail2ban >/dev/null 2>&1 || true

    log_event "INFO" "Fail2Ban is active."
    return 0
}

safe_fetch() {
    local url="$1"
    local destination="$2"

    if [ -z "$url" ] || [ -z "$destination" ]; then
        return 1
    fi

    curl -fLsS --connect-timeout 15 \
        -o "$destination" "$url"
}

update_script() {
    log_event "INFO" "Updating NginxBandits from the configured repository."

    if ! check_command git; then
        log_event "ERROR" "Git is not installed."
        return 1
    fi

    log_event "WARN" "Use the master installer for private-repository updates."
    log_event "INFO" "Current installation has been left unchanged."
    return 0
}

uninstall_script() {
    echo
    echo "WARNING: This removes NginxBandits services and files."
    read -r -p "Type REMOVE to continue: " confirmation

    if [ "$confirmation" != "REMOVE" ]; then
        echo "Uninstall cancelled."
        return 1
    fi

    local services=(
        nginxbandits-ws
        nginxbandits-dnstt
        nginxbandits-monitor
        nginxbandits-udp-custom
        janabitech-ws
        janabitech-dnstt
        janabitech-monitor
        janabitech-udp-custom
        stunnel4
        dropbear
        danted
    )

    for service in "${services[@]}"; do
        systemctl disable --now "$service" >/dev/null 2>&1 || true
        rm -f "/etc/systemd/system/${service}.service"
    done

    systemctl daemon-reload

    rm -f /usr/local/bin/nginxbandits
    rm -f /usr/local/sbin/menu

    rm -rf "$BASE_DIR"

    # Remove compatibility path only if it is a symlink.
    if [ -L /opt/janabitech ]; then
        rm -f /opt/janabitech
    fi

    log_event "INFO" "NginxBandits removed."
    return 0
}
