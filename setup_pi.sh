#!/bin/bash
# ============================================================
# setup_pi.sh — OpenClaw + Lark Agent on Raspberry Pi 5
# Run as: bash setup_pi.sh
# ============================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[SETUP]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
section() { echo -e "\n${BLUE}══════════════════════════════════════${NC}"; echo -e "${BLUE} $1${NC}"; echo -e "${BLUE}══════════════════════════════════════${NC}"; }

# ── Preflight ────────────────────────────────────────────────
section "Preflight Checks"

[[ $(uname -m) == "aarch64" ]] || warn "Not ARM64 — are you on Pi?"
[[ $(id -u) != 0 ]] || err "Don't run as root. Use a regular user."
[[ $(free -g | awk '/^Mem:/{print $2}') -ge 4 ]] || warn "Less than 4GB RAM detected"

log "Checking USB SSD..."
if lsblk | grep -q "sda"; then
  log "USB drive detected at /dev/sda"
  warn "Make sure /dev/sda1 is mounted at /data before continuing"
else
  warn "No USB SSD detected. Will use SD card (not recommended for production)"
  sudo mkdir -p /data
fi

# ── System Update ────────────────────────────────────────────
section "System Update"
sudo apt-get update -qq
sudo apt-get upgrade -y -qq
sudo apt-get install -y -qq \
  curl wget git python3 python3-pip python3-venv \
  build-essential libssl-dev libffi-dev \
  sqlite3 jq unzip htop

# ── USB SSD Setup ────────────────────────────────────────────
section "Storage Setup"
sudo mkdir -p /data/openclaw/{workspace,logs,french,jobs}
sudo chown -R $USER:$USER /data/openclaw
log "Data directories created at /data/openclaw"

# ── Node.js (for OpenClaw) ───────────────────────────────────
section "Node.js Setup"
if ! command -v node &> /dev/null; then
  curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
  sudo apt-get install -y nodejs
fi
node --version
npm --version
log "Node.js ready"

# ── Python Environment ───────────────────────────────────────
section "Python Environment"
python3 -m venv /home/$USER/venv
source /home/$USER/venv/bin/activate
pip install -q --upgrade pip
pip install -q \
  requests \
  python-dotenv \
  pyyaml \
  schedule \
  lark-oapi \
  langchain-community \
  sentence-transformers \
  chromadb \
  python-docx \
  PyMuPDF
log "Python packages installed"

# ── OpenClaw ─────────────────────────────────────────────────
section "OpenClaw Installation"
if [ ! -d "/home/$USER/.openclaw" ]; then
  git clone https://github.com/openclaw/openclaw /home/$USER/.openclaw 2>/dev/null || {
    warn "OpenClaw repo not found publicly — creating skeleton structure"
    mkdir -p /home/$USER/.openclaw/{skills,config,workspace}
  }
fi

# Copy our config files
cp -r /home/$USER/piclaw/config/* /home/$USER/.openclaw/config/
cp -r /home/$USER/piclaw/skills/* /home/$USER/.openclaw/skills/
cp -r /home/$USER/piclaw/memory/* /data/openclaw/workspace/

log "OpenClaw configured"

# ── Cloudflare Tunnel ────────────────────────────────────────
section "Cloudflare Tunnel (webhook exposure)"
if ! command -v cloudflared &> /dev/null; then
  wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-arm64.deb
  sudo dpkg -i cloudflared-linux-arm64.deb
  rm cloudflared-linux-arm64.deb
fi
cloudflared --version
log "cloudflared installed"

cat << 'TUNNEL_INSTRUCTIONS'
──────────────────────────────────────
Next steps for Cloudflare Tunnel:
1. cloudflared tunnel login
2. cloudflared tunnel create openclaw
3. Copy tunnel ID to .env
4. cloudflared tunnel route dns openclaw your-domain.com
5. sudo systemctl enable --now cloudflared
──────────────────────────────────────
TUNNEL_INSTRUCTIONS

# ── Lark Webhook Server ──────────────────────────────────────
section "Lark Webhook Server"

cat > /home/$USER/piclaw/scripts/lark_server.py << 'PYEOF'
#!/usr/bin/env python3
"""
Lark Webhook Server for OpenClaw
Handles incoming Lark events and card callbacks
"""

import json
import hashlib
import hmac
import os
from http.server import HTTPServer, BaseHTTPRequestHandler
from dotenv import load_dotenv

load_dotenv(os.path.expanduser("~/.openclaw/.env"))

VERIFICATION_TOKEN = os.getenv("LARK_VERIFICATION_TOKEN")
APP_ID = os.getenv("LARK_APP_ID")
APP_SECRET = os.getenv("LARK_APP_SECRET")

class LarkWebhookHandler(BaseHTTPRequestHandler):

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length)

        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            self._respond(400, {"error": "invalid json"})
            return

        # Lark challenge verification (first-time setup)
        if data.get("type") == "url_verification":
            challenge = data.get("challenge", "")
            print(f"[LARK] URL verification challenge received")
            self._respond(200, {"challenge": challenge})
            return

        # Route event to appropriate skill handler
        event_type = data.get("header", {}).get("event_type", "")
        event = data.get("event", {})

        print(f"[LARK] Event received: {event_type}")

        if event_type == "im.message.receive_v1":
            self._handle_message(event)
        elif event_type == "card.action.trigger":
            self._handle_card_action(event)
        else:
            print(f"[LARK] Unhandled event type: {event_type}")

        self._respond(200, {"code": 0})

    def _handle_message(self, event):
        """Route incoming messages to skills"""
        msg_type = event.get("message", {}).get("message_type")
        content = event.get("message", {}).get("content", "{}")

        if msg_type == "text":
            text = json.loads(content).get("text", "").strip()
            print(f"[MSG] Received: {text}")
            # TODO: Route to OpenClaw skill dispatcher
            self._dispatch_to_openclaw("message", {"text": text, "event": event})

        elif msg_type == "file":
            file_key = json.loads(content).get("file_key")
            print(f"[FILE] Received file: {file_key}")
            self._dispatch_to_openclaw("file_upload", {"file_key": file_key, "event": event})

    def _handle_card_action(self, event):
        """Handle button taps on interactive cards"""
        action_value = event.get("action", {}).get("value", {})
        action_type = action_value.get("action")
        print(f"[CARD] Action: {action_type}")
        self._dispatch_to_openclaw("card_action", {"action": action_type, "value": action_value, "event": event})

    def _dispatch_to_openclaw(self, event_type, payload):
        """Send event to OpenClaw skill runner"""
        # In full implementation, this calls OpenClaw's skill dispatcher
        # For now, log to file for OpenClaw to pick up
        import datetime
        event_file = f"/data/openclaw/workspace/events/{datetime.datetime.now().strftime('%Y%m%d_%H%M%S')}_{event_type}.json"
        os.makedirs(os.path.dirname(event_file), exist_ok=True)
        with open(event_file, "w") as f:
            json.dump({"type": event_type, "payload": payload}, f)
        print(f"[DISPATCH] Event written to {event_file}")

    def _respond(self, status, body):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(body).encode())

    def log_message(self, format, *args):
        pass  # Suppress default HTTP log spam

if __name__ == "__main__":
    PORT = int(os.getenv("WEBHOOK_PORT", 8080))
    server = HTTPServer(("0.0.0.0", PORT), LarkWebhookHandler)
    print(f"[LARK] Webhook server running on port {PORT}")
    server.serve_forever()
PYEOF

chmod +x /home/$USER/piclaw/scripts/lark_server.py
log "Lark webhook server created"

# ── Systemd Services ─────────────────────────────────────────
section "Systemd Services (auto-start on boot)"

# Lark webhook service
sudo tee /etc/systemd/system/piclaw.service > /dev/null << SERVICE
[Unit]
Description=OpenClaw Lark Webhook Server
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=/home/$USER/piclaw
ExecStart=/home/$USER/venv/bin/python3 /home/$USER/piclaw/scripts/lark_server.py
Restart=always
RestartSec=5
EnvironmentFile=/home/$USER/.openclaw/.env
StandardOutput=append:/data/openclaw/logs/webhook.log
StandardError=append:/data/openclaw/logs/webhook.error.log

[Install]
WantedBy=multi-user.target
SERVICE

# Cron jobs
CRON_JOBS="
# OpenClaw — French daily questions (8 AM)
0 8 * * * /home/$USER/venv/bin/python3 /home/$USER/piclaw/scripts/run_skill.py french_coach send_daily_questions >> /data/openclaw/logs/french.log 2>&1

# OpenClaw — Job scout (Mon/Wed/Fri 9 AM)
0 9 * * 1,3,5 /home/$USER/venv/bin/python3 /home/$USER/piclaw/scripts/run_skill.py job_scout find_and_report >> /data/openclaw/logs/jobs.log 2>&1

# OpenClaw — Weekly report (Sunday 10 AM)
0 10 * * 0 /home/$USER/venv/bin/python3 /home/$USER/piclaw/scripts/run_skill.py reporter send_weekly_summary >> /data/openclaw/logs/report.log 2>&1

# OpenClaw — Compile French notes (Sunday 9 PM)
0 21 * * 0 /home/$USER/venv/bin/python3 /home/$USER/piclaw/scripts/run_skill.py french_coach compile_weekly_notes >> /data/openclaw/logs/french.log 2>&1

# Rotate logs (keep last 7 days)
0 0 * * * find /data/openclaw/logs -name '*.log' -mtime +7 -delete
"

(crontab -l 2>/dev/null; echo "$CRON_JOBS") | crontab -

sudo systemctl daemon-reload
sudo systemctl enable piclaw
log "Systemd services configured"

# ── Lark App Setup Instructions ──────────────────────────────
section "Lark App Configuration"

cat << 'LARK_INSTRUCTIONS'
══════════════════════════════════════════════
LARK APP SETUP (do this at open.larksuite.com)
══════════════════════════════════════════════

1. Go to https://open.larksuite.com/app
   → Create App → Custom App
   → Name: "Aria" (or your preferred name)

2. Enable these permissions (Permissions & Scopes):
   Messaging:
   ✅ im:message                (read messages)
   ✅ im:message:send_as_bot    (send messages)
   ✅ im:resource               (download files)
   Documents:
   ✅ docx:document             (create/edit docs)
   Bitable:
   ✅ bitable:app               (job tracker table)
   Contact:
   ✅ contact:user.id:readonly  (get your user ID)

3. Event Subscriptions → Add Events:
   ✅ im.message.receive_v1    (receive messages)
   ✅ card.action.trigger      (button callbacks)

4. Set Request URL:
   https://YOUR-TUNNEL-DOMAIN.com/webhook/lark

5. Get credentials → paste into .env:
   App ID, App Secret, Verification Token

6. Find YOUR open_id:
   Message the bot "whoami" after first deploy

══════════════════════════════════════════════
LARK_INSTRUCTIONS

# ── Final Summary ────────────────────────────────────────────
section "Setup Complete! 🎉"

echo ""
echo "Next steps:"
echo "  1. Fill in credentials:  nano ~/.openclaw/.env"
echo "  2. Mount USB SSD:        sudo mount /dev/sda1 /data"
echo "  3. Setup CF tunnel:      cloudflared tunnel login"
echo "  4. Start services:       sudo systemctl start piclaw"
echo "  5. Check logs:           tail -f /data/openclaw/logs/webhook.log"
echo ""
echo "Files created:"
echo "  Config:   ~/.openclaw/config/openclaw.config.yaml"
echo "  Skills:   ~/.openclaw/skills/"
echo "  Memory:   /data/openclaw/workspace/"
echo "  Logs:     /data/openclaw/logs/"
echo ""
log "Happy agent building! 🤖"
