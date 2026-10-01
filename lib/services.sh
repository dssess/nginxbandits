#!/bin/bash

CONFIG="/opt/nginxbandits/core/nginxbandits.conf"

[ -f "$CONFIG" ] && source "$CONFIG"
source "/opt/nginxbandits/lib/system.sh" 2>/dev/null

MANAGED_SERVICES=(
    "janabitech-ws"
    "janabitech-dnstt"
    "janabitech-monitor"
    "janabitech-udp-custom"
    "stunnel4"
    "dropbear"
    "danted"
    "ssh"
    "sshd"
)

is_managed_service() {
    local target="$1"

    for service in "${MANAGED_SERVICES[@]}"; do
        [ "$target" = "$service" ] && return 0
    done

    return 1
}

service_exists() {
    local service="$1"
    systemctl cat "$service" >/dev/null 2>&1
}

restart_one_service() {
    local service_name="$1"

    if ! service_exists "$service_name"; then
        log_event "WARN" "Service not installed: $service_name"
        return 1
    fi

    systemctl restart "$service_name" >/dev/null 2>&1

    if systemctl is-active --quiet "$service_name"; then
        log_event "INFO" "Restarted: $service_name"
        return 0
    fi

    log_event "ERROR" "Failed to restart: $service_name"
    return 1
}

restart_service() {
    local service_name="$1"

    if [ -z "$service_name" ]; then
        log_event "ERROR" "No service specified."
        return 1
    fi

    if [ "$service_name" = "all" ]; then
        local failed=0

        log_event "INFO" "Restarting managed NginxBandits services..."

        for service in "${MANAGED_SERVICES[@]}"; do
            if service_exists "$service"; then
                restart_one_service "$service" || failed=1
            fi
        done

        if [ "$failed" -eq 0 ]; then
            log_event "INFO" "All available services restarted successfully."
            return 0
        fi

        log_event "WARN" "One or more services failed to restart."
        return 1
    fi

    if ! is_managed_service "$service_name"; then
        log_event "WARN" "Unauthorized or unknown service: $service_name"
        return 1
    fi

    restart_one_service "$service_name"
}

get_service_status() {
    local service_name="$1"

    if ! is_managed_service "$service_name"; then
        echo "UNKNOWN"
        return 1
    fi

    if systemctl is-active --quiet "$service_name"; then
        echo "ACTIVE"
    elif service_exists "$service_name"; then
        echo "INACTIVE"
    else
        echo "NOT INSTALLED"
    fi
}

stop_service() {
    local service_name="$1"

    if ! is_managed_service "$service_name"; then
        log_event "WARN" "Unauthorized or unknown service: $service_name"
        return 1
    fi

    if ! service_exists "$service_name"; then
        log_event "WARN" "Service not installed: $service_name"
        return 1
    fi

    systemctl stop "$service_name" >/dev/null 2>&1

    if ! systemctl is-active --quiet "$service_name"; then
        log_event "INFO" "Stopped: $service_name"
        return 0
    fi

    log_event "ERROR" "Failed to stop: $service_name"
    return 1
}
