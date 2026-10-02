NginxBandits

NginxBandits is a modular Linux VPS management system designed for simple server administration, account management, service control, and monitoring.

🚀 Features

- 👤 User Management
  
  - Create VPN/SSH accounts
  - Trial accounts
  - Account expiry & renewal
  - Delete/expire accounts
  - Simultaneous login limits
  - "0 = Unlimited"
  - Optional bandwidth limits

- 🔐 Network Services
  
  - OpenSSH
  - Dropbear
  - WebSocket
  - Stunnel/TLS
  - SOCKS/Dante
  - UDP Custom
  - DNSTT

- 📊 Server Monitoring
  
  - Online users
  - Active SSH/Dropbear sessions
  - Data usage
  - Account expiry
  - Service status
  - Automatic service restarts

- 🗄️ Database
  
  - Lightweight SQLite database
  - User records
  - UUIDs
  - Expiry dates
  - Login limits
  - Data usage and limits
  - Account status

- 🖥️ Simple Management
  
  - Interactive terminal menu
  - Command-line interface
  - Modular backend
  - systemd service management

🏗️ Architecture

Menu
  ↓
NginxBandits CLI
  ↓
Backend Libraries
  ↓
Database / Services / System

📁 Installation

Requirements:

- Linux VPS
- Root access
- systemd
- Internet connection

Install:

git clone <REPOSITORY_URL>
cd nginxbandits
chmod +x install.sh
sudo ./install.sh

The installer configures the system through four stages:

01 - Core Setup
02 - Routing
03 - Sidecar Services
04 - Monitoring

⚙️ Main Commands

nginxbandits

Legacy-compatible command:

janabitech

Interactive menu:

menu

📂 Installation

Main directory:

/opt/nginxbandits

Compatibility path:

/opt/janabitech

🔒 Security

NginxBandits includes:

- Protected database permissions
- Protected private keys
- SSH configuration validation
- Managed-service controls
- Automatic account expiry
- No credentials or private keys committed to the repository

Use the system only on servers and networks you are authorized to manage.

🧪 Project Status

NginxBandits is actively developed with a focus on:

Stability • Compatibility • Monitoring • Simple Management

---

👨‍💻 Project

NginxBandits
GitHub: "dssess/nginxbandits"
