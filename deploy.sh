#!/usr/bin/env bash
# Simple Docker App Deployment Script (DevOps Beginner Friendly)
# --------------------------------------------------------------
# Features:
#  - Deploys a Dockerized app to a remote server via SSH
#  - Updates system packages on remote
#  - Starts Docker service if stopped
#  - Runs Docker Compose or Dockerfile builds
#  - Creates Nginx reverse proxy config
#  - Tests and reloads Nginx
#  - Performs health checks on the deployed app
#
# Usage: ./deploy.sh
# --------------------------------------------------------------

set -e  # Exit immediately on errors

# -----------------------------
# Step 1: Simple Logging
# -----------------------------
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() {
  echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# -----------------------------
# Step 2: Collect Input
# -----------------------------
echo "=== Simple Docker Deployment Script ==="
read -p "Enter Git repository URL (e.g. https://github.com/user/repo.git): " REPO_URL
read -p "Enter branch to deploy [main]: " BRANCH
BRANCH=${BRANCH:-main}
read -p "Enter SSH username (e.g. ubuntu): " SERVER_USER
read -p "Enter server IP address: " SERVER_IP
read -p "Enter path to SSH private key (e.g. ~/.ssh/id_rsa): " SSH_KEY
read -p "Enter internal app port (e.g. 5000): " APP_PORT

PROJECT_NAME=$(basename -s .git "$REPO_URL")
REMOTE_DIR="/home/$SERVER_USER/$PROJECT_NAME"

log "Project: $PROJECT_NAME"
log "Remote: $SERVER_USER@$SERVER_IP"
log "Branch: $BRANCH"
log "Remote directory: $REMOTE_DIR"

# -----------------------------
# Step 3: Clone or Update Repo
# -----------------------------
if [ -d "$PROJECT_NAME" ]; then
  log "Local project exists. Pulling latest..."
  cd "$PROJECT_NAME"
  git pull origin "$BRANCH" || { log "Git pull failed"; exit 1; }
  cd ..
else
  log "Cloning repository..."
  git clone -b "$BRANCH" "$REPO_URL" || { log "Git clone failed"; exit 1; }
fi

# -----------------------------
# Step 4: Check SSH
# -----------------------------
log "Testing SSH connection..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes "$SERVER_USER@$SERVER_IP" "echo connected" >/dev/null 2>&1; then
  log "❌ SSH connection failed. Check your key or IP."
  exit 1
fi
log "✅ SSH connection OK."

# -----------------------------
# Step 5: Update Packages & Ensure Docker/Nginx Installed
# -----------------------------
log "Updating packages and ensuring Docker + Nginx are installed..."
ssh -i "$SSH_KEY" "$SERVER_USER@$SERVER_IP" bash <<EOF
set -e
sudo apt-get update -y
sudo apt-get install -y docker.io docker-compose nginx curl
sudo systemctl enable --now docker
sudo systemctl enable --now nginx
EOF
log "✅ Packages updated and services ensured."

# -----------------------------
# Step 6: Copy Files to Server
# -----------------------------
log "Copying project to remote..."
scp -i "$SSH_KEY" -r "$PROJECT_NAME" "$SERVER_USER@$SERVER_IP:$REMOTE_DIR" >/dev/null 2>&1 || {
  log "File transfer failed!"
  exit 1
}
log "✅ Files copied."

# -----------------------------
# Step 7: Deploy App on Remote
# -----------------------------
log "Deploying app using Docker..."
ssh -i "$SSH_KEY" "$SERVER_USER@$SERVER_IP" bash <<EOF
set -e
cd "$REMOTE_DIR"

# Start Docker service if stopped
sudo systemctl start docker || true

if [ -f docker-compose.yml ]; then
  echo "🟢 Using docker-compose..."
  sudo docker compose down || true
  sudo docker compose up -d --build
elif [ -f Dockerfile ]; then
  echo "🟢 Using Dockerfile..."
  sudo docker build -t "$PROJECT_NAME" .
  sudo docker stop "$PROJECT_NAME" || true
  sudo docker rm "$PROJECT_NAME" || true
  sudo docker run -d --name "$PROJECT_NAME" -p $APP_PORT:$APP_PORT "$PROJECT_NAME"
else
  echo "❌ No Dockerfile or docker-compose.yml found."
  exit 1
fi
EOF
log "✅ App deployed on remote."

# -----------------------------
# Step 8: Docker Health & Service Check
# -----------------------------
log "Checking Docker service and container status..."
ssh -i "$SSH_KEY" "$SERVER_USER@$SERVER_IP" bash <<EOF
set -e
sudo systemctl is-active --quiet docker && echo "✅ Docker service is running" || (echo "❌ Docker service not running"; exit 1)
echo "🧩 Active containers:"
sudo docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
EOF

# -----------------------------
# Step 9: Nginx Reverse Proxy Setup
# -----------------------------
log "Setting up Nginx reverse proxy..."

NGINX_CONF="/etc/nginx/sites-available/$PROJECT_NAME.conf"

ssh -i "$SSH_KEY" "$SERVER_USER@$SERVER_IP" bash <<EOF
set -e
# Create Nginx config
sudo bash -c 'cat > $NGINX_CONF <<NGINX_EOF
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://127.0.0.1:$APP_PORT;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }
}
NGINX_EOF'

# Enable site
sudo ln -sf $NGINX_CONF /etc/nginx/sites-enabled/$PROJECT_NAME.conf

# Test & reload
sudo nginx -t
sudo systemctl reload nginx
EOF

log "✅ Nginx proxy configured and reloaded."

# -----------------------------
# Step 10: Health Check
# -----------------------------
log "Performing HTTP health check..."
if curl -s -I "http://$SERVER_IP" | grep -q "200 OK"; then
  log "✅ App is reachable via Nginx!"
else
  log "⚠️ App not responding with 200 OK. Check container logs on the server."
fi

log "🎉 Deployment complete! Check $LOG_FILE for logs."
