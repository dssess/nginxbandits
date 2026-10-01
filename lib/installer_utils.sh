#!/bin/bash

CONFIG="/opt/nginxbandits/core/nginxbandits.conf"

if [ -f "$CONFIG" ]; then
    source "$CONFIG"
fi

source "/opt/nginxbandits/lib/system.sh" 2>/dev/null

run_with_spinner() {
    local message="$1"
    shift

    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'

    "$@" >/dev/null 2>&1 &
    local pid=$!

    tput civis 2>/dev/null || true
    printf "  \033[0;36m%s\033[0m " "$message"

    while kill -0 "$pid" 2>/dev/null; do
        printf "[\033[0;32m%c\033[0m]" "${spinstr:0:1}"
        spinstr="${spinstr:1}${spinstr:0:1}"
        sleep "$delay"
        printf "\b\b\b"
    done

    wait "$pid"
    local status=$?

    tput cnorm 2>/dev/null || true

    if [ "$status" -eq 0 ]; then
        printf "[\033[0;32m✓\033[0m]\n"
    else
        printf "[\033[0;31m✗\033[0m]\n"
    fi

    return "$status"
}

ensure_package() {
    local package="$1"

    if [ -z "$package" ]; then
        return 1
    fi

    if dpkg -s "$package" >/dev/null 2>&1; then
        log_event "INFO" "Dependency already installed: $package"
        return 0
    fi

    log_event "INFO" "Installing dependency: $package"

    run_with_spinner \
        "Installing $package..." \
        env DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "$package"
}

safe_create_dir() {
    local directory="$1"

    if [ -z "$directory" ]; then
        return 1
    fi

    if [ ! -d "$directory" ]; then
        mkdir -p "$directory" || {
            log_event "ERROR" "Failed to create directory: $directory"
            return 1
        }

        log_event "INFO" "Created directory: $directory"
    fi

    return 0
}

safe_deploy_systemd() {
    local service_name="$1"
    local temp_file="/tmp/${service_name}.service.tmp"
    local service_file="/etc/systemd/system/${service_name}.service"

    if [ -z "$service_name" ]; then
        log_event "ERROR" "No systemd service name supplied."
        return 1
    fi

    if [ ! -f "$temp_file" ]; then
        log_event "ERROR" "Systemd temporary file missing: $temp_file"
        return 1
    fi

    if [ -f "$service_file" ] && cmp -s "$temp_file" "$service_file"; then
        log_event "INFO" "Service unchanged: $service_name"
        rm -f "$temp_file"
        return 0
    fi

    install -m 0644 "$temp_file" "$service_file" || {
        log_event "ERROR" "Failed to install systemd unit: $service_name"
        rm -f "$temp_file"
        return 1
    }

    rm -f "$temp_file"

    systemctl daemon-reload || return 1
    systemctl enable "$service_name" >/dev/null 2>&1 || return 1
    systemctl restart "$service_name" >/dev/null 2>&1 || {
        log_event "ERROR" "Service failed after deployment: $service_name"
        return 1
    }

    if systemctl is-active --quiet "$service_name"; then
        log_event "INFO" "Systemd service deployed successfully: $service_name"
        return 0
    fi

    log_event "ERROR" "Systemd service is not active: $service_name"
    return 1
}

ensure_tls_cert() {
    local domain="$1"
    local key_dir="/opt/nginxbandits/core/keys"
    local cert_path="${key_dir}/stunnel.pem"

    if [ -z "$domain" ]; then
        log_event "ERROR" "Cannot generate TLS certificate without a domain."
        return 1
    fi

    safe_create_dir "$key_dir" || return 1

    if [ -s "$cert_path" ]; then
        log_event "INFO" "TLS certificate already exists."
        return 0
    fi

    log_event "INFO" "Generating self-signed TLS fallback for $domain"

    run_with_spinner \
        "Generating TLS certificate..." \
        openssl req -x509 -nodes -days 3650 \
        -newkey rsa:2048 \
        -keyout "${key_dir}/private.key" \
        -out "${key_dir}/fullchain.cer" \
        -subj "/C=KE/O=NginxBandits/CN=${domain}" || return 1

    cat "${key_dir}/fullchain.cer" \
        "${key_dir}/private.key" > "$cert_path" || return 1

    chmod 600 \
        "${key_dir}/private.key" \
        "${key_dir}/fullchain.cer" \
        "$cert_path"

    log_event "INFO" "Self-signed TLS fallback created."
    return 0
}
