#!/bin/bash
set -e

# ==============================================================================
# TASKFLOW — AWS EC2 USER DATA AUTOMATED PROVISIONING SCRIPT
# Region: ap-south-1 (Mumbai) | OS: Ubuntu 24.04 LTS / 22.04 LTS
# ==============================================================================

LOG_FILE="/var/log/taskflow-init.log"
exec > >(tee -a "${LOG_FILE}") 2>&1

echo "=================================================================="
echo "Starting TaskFlow Automated EC2 Deployment at $(date)"
echo "=================================================================="

# 1. CONFIGURE 2GB SWAP MEMORY (Prevents OOM during Vite builds on t3.micro/small)
if [ ! -f /swapfile ]; then
    echo "[1/8] Configuring 2GB Swap Memory..."
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
    chmod 600 /swapfile
    mkswap /swapfile
    swapon /swapfile
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# 2. UPDATE SYSTEM PACKAGES & INSTALL RUNTIME DEPENDENCIES
echo "[2/8] Installing System Dependencies (Nginx, Python 3, Build Tools)..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y nginx git curl build-essential python3 python3-pip python3-venv python3-dev

# 3. INSTALL NODE.JS 20 LTS VIA NODESOURCE
echo "[3/8] Installing Node.js 20 LTS..."
if ! command -v node &> /dev/null; then
    curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
    apt-get install -y nodejs
fi
node -v
npm -v

# 4. PREPARE APPLICATION DIRECTORY & PERMISSIONS
APP_DIR="/var/www/taskflow"
echo "[4/8] Preparing Application Directory at ${APP_DIR}..."
mkdir -p "${APP_DIR}"
mkdir -p "${APP_DIR}/database"
mkdir -p "${APP_DIR}/uploads/chat"

# Note: In production, clone or unpack the repository into ${APP_DIR}
# Example: git clone <YOUR_REPO_URL> "${APP_DIR}"
# If files are already present in ${APP_DIR}, proceed.

cd "${APP_DIR}"

# 5. CONFIGURE PYTHON VIRTUAL ENVIRONMENT & RUNTIME DEPENDENCIES
echo "[5/8] Setting Up Python Virtual Environment..."
if [ ! -d "${APP_DIR}/venv" ]; then
    python3 -m venv "${APP_DIR}/venv"
fi
"${APP_DIR}/venv/bin/pip" install --upgrade pip
if [ -f "${APP_DIR}/backend/requirements.txt" ]; then
    "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/backend/requirements.txt"
elif [ -f "${APP_DIR}/requirements.txt" ]; then
    "${APP_DIR}/venv/bin/pip" install -r "${APP_DIR}/requirements.txt"
fi

# 6. BUILD FRONTEND STATIC ASSETS
echo "[6/8] Building Frontend Static Assets..."
if [ -d "${APP_DIR}/frontend" ]; then
    cd "${APP_DIR}/frontend"
    npm install
    npm run build
    cd "${APP_DIR}"
fi

# 7. CONFIGURE NGINX REVERSE PROXY
echo "[7/8] Configuring Nginx Reverse Proxy with WebSocket Upgrades..."
cat << 'EOF' > /etc/nginx/sites-available/taskflow
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    root /var/www/taskflow/frontend/dist;
    index index.html;

    client_max_body_size 35M;

    gzip on;
    gzip_vary on;
    gzip_min_length 1024;
    gzip_proxied any;
    gzip_types text/plain text/css text/xml application/json application/javascript application/xml+rss application/atom+xml image/svg+xml;

    location /assets/ {
        expires 1y;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    location /api/ {
        proxy_pass http://127.0.0.1:5000/api/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 120s;
        proxy_connect_timeout 10s;
    }

    location /socket.io/ {
        proxy_pass http://127.0.0.1:5000/socket.io/;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "Upgrade";
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
        proxy_buffering off;
    }

    location / {
        try_files $uri $uri/ /index.html;
    }
}
EOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/taskflow /etc/nginx/sites-enabled/
nginx -t
systemctl restart nginx

# 8. CONFIGURE SYSTEMD SERVICE & START BACKEND
echo "[8/8] Configuring systemd Service for TaskFlow Backend..."
cat << 'EOF' > /etc/systemd/system/taskflow.service
[Unit]
Description=TaskFlow Flask-SocketIO Production Application
After=network.target

[Service]
Type=simple
User=www-data
Group=www-data
WorkingDirectory=/var/www/taskflow
EnvironmentFile=-/var/www/taskflow/.env
ExecStart=/var/www/taskflow/venv/bin/python -m backend.app
Restart=always
RestartSec=5s
StandardOutput=append:/var/log/taskflow.log
StandardError=append:/var/log/taskflow.err.log

[Install]
WantedBy=multi-user.target
EOF

# Ensure proper ownership of directories
chown -R www-data:www-data "${APP_DIR}"
chmod -R 775 "${APP_DIR}/database"
chmod -R 775 "${APP_DIR}/uploads"

systemctl daemon-reload
systemctl enable taskflow
systemctl restart taskflow

echo "=================================================================="
echo "TaskFlow Deployment Completed Successfully at $(date)"
echo "Logs available at: ${LOG_FILE}"
echo "=================================================================="
