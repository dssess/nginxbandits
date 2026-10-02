#!/bin/bash

CONFIG="/opt/nginxbandits/core/nginxbandits.conf"

if [ -f "$CONFIG" ]; then
    source "$CONFIG"
else
    DB_PATH="/opt/nginxbandits/core/database.db"
    MAX_LOGINS_DEFAULT=2
fi

source "/opt/nginxbandits/lib/db.sh" 2>/dev/null
source "/opt/nginxbandits/lib/system.sh" 2>/dev/null

validate_username() {
    local username="$1"

    if [[ ! "$username" =~ ^[a-zA-Z0-9_-]{3,32}$ ]]; then
        log_event "ERROR" "Invalid username: $username"
        return 1
    fi

    return 0
}

validate_number() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

create_vpn_user() {
    local username="$1"
    local password="$2"
    local days="$3"
    local max_logins="${4-$MAX_LOGINS_DEFAULT}"
    local bw_limit_gb="${5:-0}"

    validate_username "$username" || return 3

    if [[ -z "$password" || -z "$days" ]]; then
        log_event "ERROR" "Missing account creation arguments."
        return 1
    fi

    validate_number "$days" || return 1
    validate_number "$max_logins" || return 1
    validate_number "$bw_limit_gb" || return 1

    if db_user_exists "$username"; then
        log_event "WARN" "User already exists: $username"
        return 2
    fi

    if id "$username" >/dev/null 2>&1; then
        log_event "WARN" "Linux user already exists: $username"
        return 2
    fi

    local expiry_date
    local os_expiry_date
    local uuid
    local data_limit_bytes

    expiry_date="$(date -d "+${days} days" '+%Y-%m-%d %H:%M:%S')" || return 1
    os_expiry_date="$(date -d "+${days} days" '+%Y-%m-%d')" || return 1
    uuid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    data_limit_bytes=$((bw_limit_gb * 1073741824))

    useradd \
        -e "$os_expiry_date" \
        -s /bin/false \
        -M \
        "$username" >/dev/null 2>&1 || {
        log_event "ERROR" "Failed to create Linux user: $username"
        return 1
    }

    if ! echo "$username:$password" | chpasswd; then
        userdel -f "$username" >/dev/null 2>&1
        log_event "ERROR" "Failed to set password for: $username"
        return 1
    fi

    db_query "INSERT INTO users
        (username, uuid, expiry_date, max_logins, data_limit, status)
        VALUES
        ('$username', '$uuid', '$expiry_date', $max_logins, $data_limit_bytes, 'ACTIVE');"

    if [ $? -ne 0 ]; then
        userdel -f "$username" >/dev/null 2>&1
        log_event "ERROR" "Database registration failed for: $username"
        return 1
    fi

    log_event "INFO" "Created user $username for $days days."
    return 0
}

create_trial_user() {
    local username="$1"
    local password="$2"
    local hours="$3"
    local max_logins="${4-$MAX_LOGINS_DEFAULT}"
    local bw_limit_gb="${5:-0}"

    validate_username "$username" || return 3

    if [[ -z "$password" || -z "$hours" ]]; then
        log_event "ERROR" "Missing trial creation arguments."
        return 1
    fi

    validate_number "$hours" || return 1
    validate_number "$max_logins" || return 1
    validate_number "$bw_limit_gb" || return 1

    if db_user_exists "$username" || id "$username" >/dev/null 2>&1; then
        return 2
    fi

    local expiry_date
    local uuid
    local data_limit_bytes

    expiry_date="$(date -d "+${hours} hours" '+%Y-%m-%d %H:%M:%S')" || return 1
    uuid="$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)"
    data_limit_bytes=$((bw_limit_gb * 1073741824))

    useradd -M -s /bin/false "$username" >/dev/null 2>&1 || {
        log_event "ERROR" "Failed to create trial user: $username"
        return 1
    }

    if ! echo "$username:$password" | chpasswd; then
        userdel -f "$username" >/dev/null 2>&1
        return 1
    fi

    db_query "INSERT INTO users
        (username, uuid, expiry_date, max_logins, data_limit, status)
        VALUES
        ('$username', '$uuid', '$expiry_date', $max_logins, $data_limit_bytes, 'ACTIVE');"

    if [ $? -ne 0 ]; then
        userdel -f "$username" >/dev/null 2>&1
        return 1
    fi

    log_event "INFO" "Created trial user $username for $hours hours."
    return 0
}

renew_user() {
    local username="$1"
    local mod_days="$2"

    if [[ -z "$username" || -z "$mod_days" ]]; then
        return 1
    fi

    validate_number "${mod_days#-}" || return 1

    local current_expiry
    current_expiry="$(db_query \
        "SELECT expiry_date FROM users WHERE username='$username' LIMIT 1;")"

    if [[ -z "$current_expiry" ]]; then
        log_event "ERROR" "User not found: $username"
        return 2
    fi

    local current_epoch
    local mod_seconds
    local new_epoch
    local new_expiry
    local os_expiry

    current_epoch="$(date -d "$current_expiry" +%s)" || return 1
    mod_seconds=$((mod_days * 86400))
    new_epoch=$((current_epoch + mod_seconds))

    new_expiry="$(date -d "@$new_epoch" '+%Y-%m-%d %H:%M:%S')" || return 1
    os_expiry="$(date -d "@$new_epoch" '+%Y-%m-%d')" || return 1

    usermod -e "$os_expiry" "$username" >/dev/null 2>&1

    db_query "UPDATE users
              SET expiry_date='$new_expiry', status='ACTIVE'
              WHERE username='$username';"

    usermod -U "$username" >/dev/null 2>&1

    log_event "INFO" "Renewed user $username until $new_expiry."
    return 0
}

delete_vpn_user() {
    local username="$1"

    if [[ -z "$username" ]]; then
        return 1
    fi

    if id "$username" >/dev/null 2>&1; then
        pkill -u "$username" >/dev/null 2>&1 || true
        userdel -f "$username" >/dev/null 2>&1
    fi

    db_query "UPDATE users
              SET status='DELETED'
              WHERE username='$username';"

    log_event "INFO" "Deleted user: $username"
    return 0
}

expire_vpn_user() {
    local username="$1"

    if [[ -z "$username" ]]; then
        return 1
    fi

    if id "$username" >/dev/null 2>&1; then
        pkill -u "$username" >/dev/null 2>&1 || true
        userdel -f "$username" >/dev/null 2>&1
    fi

    db_query "UPDATE users
              SET status='EXPIRED'
              WHERE username='$username';"

    log_event "INFO" "Expired user removed: $username"
    return 0
}
