#!/usr/bin/env bash
# Simple Deploy Script (Beginner Friendly)
# -----------------------------------------
# This script helps you deploy a Dockerized app to a remote Linux server.
# It assumes you have:
#   - Git installed
#   - Docker installed on the remote server
#   - SSH access to the server
#
# Usage:
#   ./deploy.sh
#
# NOTE: This version is simplified for learning DevOps basics.

set -e  # Stop script if any command fails

# -----------------------------
# Step 1: Simple Logging Setup
# -----------------------------
LOG_FILE="deploy_$(date +%Y%m%d_%H%M%S).log"

log() {
  echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# -----------------------------
# Step 2: Collect User Inputs
# -----------------------------
echo "=== App Deployment Script ==="

read -p "Enter your Git repository URL (e.g., https://github.com/user/repo.git): " REPO_URL
read -p "Enter branch to deploy [main]: " BRANCH
BRANCH=${BRANCH:-main}

read -p "Enter your SSH username (e.g., ubuntu): " SERVER_USER
read -p "Enter your server IP address: " SERVER_IP
read -p "Enter path to your SSH private key (e.g., ~/.ssh/id_rsa): " SSH_KEY
read -p "Enter the port your app runs on inside Docker (e.g., 5000): " APP_PORT

PROJECT_NAME=$(basename -s .git "$REPO_URL")
REMOTE_DIR="/home/$SERVER_USER/$PROJECT_NAME"

log "Project name: $PROJECT_NAME"
log "Branch: $BRANCH"
log "Remote directory: $REMOTE_DIR"

# -----------------------------
# Step 3: Clone or Update Repo
# -----------------------------
if [ -d "$PROJECT_NAME" ]; then
  log "Local copy found. Pulling latest changes..."
  cd "$PROJECT_NAME"
  git pull origin "$BRANCH" || { log "Git pull failed"; exit 1; }
  cd ..
else
  log "Cloning repository..."
  git clone -b "$BRANCH" "$REPO_URL" || { log "Git clone failed"; exit 1; }
fi

# -----------------------------
# Step 4: Check SSH Connection
# -----------------------------
log "Checking SSH connection..."
if ! ssh -i "$SSH_KEY" -o BatchMode=yes "$SERVER_USER@$SERVER_IP" "echo connected" >/dev/null 2>&1; then
  log "SSH connection failed. Check your key or server IP."
  exit 1
fi
log "SSH connection OK."

# -----------------------------
# Step 5: Transfer Files
# -----------------------------
log "Copying project files to server..."
scp -i "$SSH_KEY" -r "$PROJECT_NAME" "$SERVER_USER@$SERVER_IP:$REMOTE_DIR" >/dev/null 2>&1 || {
  log "File transfer failed"
  exit 1
}
log "Files transferred."

# -----------------------------
# Step 6: Deploy on Remote Server
# -----------------------------
log "Deploying app on remote server..."

ssh -i "$SSH_KEY" "$SERVER_USER@$SERVER_IP" <<EOF
set -e
cd "$REMOTE_DIR"

if [ -f docker-compose.yml ]; then
  echo "Using docker-compose..."
  docker compose down || true
  docker compose up -d --build
elif [ -f Dockerfile ]; then
  echo "Using Dockerfile..."
  docker build -t $PROJECT_NAME .
  docker stop $PROJECT_NAME || true
  docker rm $PROJECT_NAME || true
  docker run -d --name $PROJECT_NAME -p $APP_PORT:$APP_PORT $PROJECT_NAME
else
  echo "No Dockerfile or docker-compose.yml found."
  exit 1
fi
EOF

log "Deployment complete."

# -----------------------------
# Step 7: Test the Deployment
# -----------------------------
log "Testing app availability..."
if curl -s "http://$SERVER_IP" >/dev/null; then
  log "App appears to be running successfully!"
else
  log "App may not be responding. Check container logs on the server."
fi

log "All done! Check $LOG_FILE for logs."
