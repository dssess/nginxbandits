#!/usr/bin/env python3

import datetime
import os
import pwd
import sqlite3
import subprocess
import time
from collections import defaultdict

BASE_DIR = "/opt/nginxbandits"
DB_PATH = f"{BASE_DIR}/core/database.db"
ONLINE_FILE = f"{BASE_DIR}/core/online_users.txt"
CHECK_INTERVAL = 30


class NginxBanditsMonitor:

    def __init__(self):
        self.db_path = DB_PATH
        self.active_sessions = defaultdict(list)
        self.pid_io_cache = {}

    def log(self, level, message):
        timestamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        line = f"[{timestamp}] [{level}] {message}"

        print(line, flush=True)

        try:
            os.makedirs(f"{BASE_DIR}/logs", exist_ok=True)

            with open(
                f"{BASE_DIR}/logs/nginxbandits.log",
                "a",
                encoding="utf-8"
            ) as logfile:
                logfile.write(line + "\n")

        except OSError:
            pass

    def database(self):
        return sqlite3.connect(self.db_path, timeout=10)

    def fetch_active_users(self):
        try:
            with self.database() as conn:
                cursor = conn.cursor()

                cursor.execute(
                    """
                    SELECT username, expiry_date, data_usage, data_limit
                    FROM users
                    WHERE status = 'ACTIVE'
                    """
                )

                return {
                    row[0]: {
                        "expiry": row[1],
                        "data_usage": row[2] or 0,
                        "data_limit": row[3] or 0
                    }
                    for row in cursor.fetchall()
                }

        except Exception as exc:
            self.log("ERROR", f"Database read failed: {exc}")
            return {}

    def reconcile_sessions(self):
        self.active_sessions.clear()

        try:
            result = subprocess.run(
                ["ps", "-eo", "user=,pid=,comm="],
                capture_output=True,
                text=True,
                check=False
            )

            ignored = {
                "root",
                "nobody",
                "syslog",
                "messagebus",
                "danted",
                "systemd-resolve"
            }

            for line in result.stdout.splitlines():
                parts = line.split()

                if len(parts) < 3:
                    continue

                username = parts[0]
                pid = parts[1]
                command = parts[2]

                if command not in {"sshd", "dropbear"}:
                    continue

                if username in ignored:
                    continue

                try:
                    account = pwd.getpwnam(username)

                    if account.pw_shell != "/bin/false":
                        continue

                except KeyError:
                    continue

                self.active_sessions[username].append(pid)

        except Exception as exc:
            self.log("ERROR", f"Session scan failed: {exc}")

    def process_bandwidth(self):
        usage_updates = {}
        current_pids = set()

        for username, pids in self.active_sessions.items():

            for pid in pids:
                current_pids.add(pid)

                try:
                    with open(f"/proc/{pid}/io", "r") as proc_io:
                        read_bytes = 0
                        write_bytes = 0

                        for line in proc_io:
                            if line.startswith("rchar:"):
                                read_bytes = int(line.split()[1])

                            elif line.startswith("wchar:"):
                                write_bytes = int(line.split()[1])

                        current_total = read_bytes + write_bytes
                        previous_total = self.pid_io_cache.get(pid, 0)

                        if current_total >= previous_total:
                            delta = current_total - previous_total
                        else:
                            delta = current_total

                        self.pid_io_cache[pid] = current_total

                        if delta > 0:
                            usage_updates[username] = (
                                usage_updates.get(username, 0) + delta
                            )

                except (
                    FileNotFoundError,
                    PermissionError,
                    ValueError
                ):
                    continue

        self.pid_io_cache = {
            pid: value
            for pid, value in self.pid_io_cache.items()
            if pid in current_pids
        }

        if not usage_updates:
            return

        try:
            with self.database() as conn:
                cursor = conn.cursor()

                for username, amount in usage_updates.items():
                    cursor.execute(
                        """
                        UPDATE users
                        SET data_usage = data_usage + ?
                        WHERE username = ?
                        """,
                        (amount, username)
                    )

                conn.commit()

        except Exception as exc:
            self.log("ERROR", f"Bandwidth update failed: {exc}")

    def enforce_expiry(self):
        now = datetime.datetime.now()

        try:
            with self.database() as conn:
                cursor = conn.cursor()

                cursor.execute(
                    """
                    SELECT username, expiry_date
                    FROM users
                    WHERE status = 'ACTIVE'
                    """
                )

                users = cursor.fetchall()

                for username, expiry in users:

                    try:
                        expiry_time = datetime.datetime.strptime(
                            expiry,
                            "%Y-%m-%d %H:%M:%S"
                        )

                    except ValueError:
                        self.log(
                            "WARN",
                            f"Invalid expiry date for {username}: {expiry}"
                        )
                        continue

                    if now < expiry_time:
                        continue

                    self.log(
                        "INFO",
                        f"Account expired: {username}"
                    )

                    subprocess.run(
                        ["pkill", "-u", username],
                        check=False,
                        stderr=subprocess.DEVNULL
                    )

                    subprocess.run(
                        ["userdel", "-f", username],
                        check=False,
                        stderr=subprocess.DEVNULL
                    )

                    cursor.execute(
                        """
                        UPDATE users
                        SET status = 'EXPIRED'
                        WHERE username = ?
                        """,
                        (username,)
                    )

                conn.commit()

        except Exception as exc:
            self.log("ERROR", f"Expiry processing failed: {exc}")

    def write_online_report(self):
        try:
            os.makedirs(
                os.path.dirname(ONLINE_FILE),
                exist_ok=True
            )

            with open(
                ONLINE_FILE,
                "w",
                encoding="utf-8"
            ) as report:

                if not self.active_sessions:
                    report.write(
                        "No active VPN connections right now.\n"
                    )
                    return

                for username, pids in sorted(
                    self.active_sessions.items()
                ):
                    report.write(
                        f"{username}|{len(pids)}\n"
                    )

        except OSError as exc:
            self.log(
                "ERROR",
                f"Online report failed: {exc}"
            )

    def run_cycle(self):
        active_users = self.fetch_active_users()

        self.reconcile_sessions()
        self.process_bandwidth()
        self.enforce_expiry()
        self.write_online_report()

        self.log(
            "INFO",
            f"Monitor cycle complete: "
            f"{len(active_users)} active accounts, "
            f"{len(self.active_sessions)} connected users."
        )

    def run(self):
        self.log(
            "INFO",
            "NginxBandits monitor started."
        )

        while True:
            try:
                self.run_cycle()

            except Exception as exc:
                self.log(
                    "ERROR",
                    f"Monitor cycle failed: {exc}"
                )

                time.sleep(15)

            time.sleep(CHECK_INTERVAL)


if __name__ == "__main__":
    NginxBanditsMonitor().run()
