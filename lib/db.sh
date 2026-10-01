#!/bin/bash

CONFIG="/opt/nginxbandits/core/nginxbandits.conf"

if [ -f "$CONFIG" ]; then
    source "$CONFIG"
else
    DB_PATH="/opt/nginxbandits/core/database.db"
    LOG_DIR="/opt/nginxbandits/logs"
fi

init_database() {
    mkdir -p "$(dirname "$DB_PATH")"
    chmod 700 "$(dirname "$DB_PATH")"

    sqlite3 "$DB_PATH" <<'SQL'
CREATE TABLE IF NOT EXISTS users (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    username TEXT UNIQUE NOT NULL,
    uuid TEXT,
    protocols TEXT DEFAULT 'ssh,ws,socks',
    expiry_date TEXT NOT NULL,
    max_logins INTEGER DEFAULT 2,
    bandwidth_limit_mb INTEGER DEFAULT 0,
    bandwidth_used_mb INTEGER DEFAULT 0,
    status TEXT DEFAULT 'ACTIVE',
    created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
    data_usage INTEGER DEFAULT 0,
    data_limit INTEGER DEFAULT 0
);
SQL

    chmod 600 "$DB_PATH"
}

db_query() {
    sqlite3 "$DB_PATH" "$1"
}

db_user_exists() {
    local username="$1"
    [ "$(sqlite3 "$DB_PATH" \
        "SELECT COUNT(*) FROM users WHERE username='$username';" 2>/dev/null)" -gt 0 ]
}
