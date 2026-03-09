# Aria — OpenClaw Agent on Raspberry Pi 5
### Lark (US Edition) · Moonshot/Kimi · French Coach · Job Scout

---

## What This Agent Does

| Skill | Frequency | Channel |
|---|---|---|
| 🇫🇷 Daily French practice questions | Every day 8 AM | Lark card |
| ✅ Grade your answers + feedback | On reply | Lark card |
| 📚 Compile weekly French notes | Sunday 9 PM | Lark Doc |
| 💼 Find matching job positions | Mon/Wed/Fri | Lark cards |
| 📋 Draft cover letters for approval | On request | Lark Doc |
| 📊 Weekly summary report | Sunday 10 AM | Lark card |

---

## Architecture

```
┌─────────────────────────────────────────────────┐
│              Raspberry Pi 5 (16GB)               │
│                                                  │
│  ┌──────────────┐    ┌────────────────────────┐  │
│  │   Cron Jobs  │    │  Lark Webhook Server   │  │
│  │  (scheduler) │    │  lark_server.py :8080  │  │
│  └──────┬───────┘    └──────────┬─────────────┘  │
│         │                       │                │
│         ▼                       ▼                │
│  ┌─────────────────────────────────────────────┐ │
│  │           OpenClaw Skill Runner             │ │
│  │  french_coach | job_scout | reporter        │ │
│  └──────────────────┬──────────────────────────┘ │
│                     │                            │
│         ┌───────────┼───────────┐               │
│         ▼           ▼           ▼               │
│    Memory.md   Moonshot API  USB SSD            │
│    PROGRESS.md  (Kimi K2.5)  /data/openclaw     │
│                                                  │
└──────────────────┬──────────────────────────────┘
                   │ Cloudflare Tunnel
                   ▼
         ┌──────────────────┐
         │   Lark (User)    │
         │  Interactive     │
         │  Cards + Docs    │
         └──────────────────┘
```

---

## Hardware Setup

### Required
- Raspberry Pi 5 (16GB RAM)
- 256GB+ SD card (OS)
- **USB SSD (highly recommended)** — for OpenClaw workspace, logs
- Active cooling (heatsink + fan) — agent workloads cause throttling

### USB SSD Setup
```bash
sudo mkfs.ext4 /dev/sda1
sudo mkdir /data
sudo mount /dev/sda1 /data
# Make it persistent:
echo '/dev/sda1 /data ext4 defaults,noatime 0 2' | sudo tee -a /etc/fstab
```

---

## Installation

### Step 1 — Clone this repo onto Pi
```bash
git clone https://github.com/x1linwang/piclaw ~/piclaw
cd ~/piclaw
```

### Step 2 — Run setup script
```bash
chmod +x scripts/setup_pi.sh
bash scripts/setup_pi.sh
```

### Step 3 — Fill in credentials
```bash
cp config/.env.template ~/.openclaw/.env
nano ~/.openclaw/.env
```

Fill in:
- `LARK_APP_ID` and `LARK_APP_SECRET` from open.larksuite.com
- `MOONSHOT_API_KEY` from platform.moonshot.cn
- `USER_LARK_OPEN_ID` (send "whoami" to bot after setup)

### Step 4 — Create Lark App

1. Go to **https://open.larksuite.com/app**
2. Click **Create Custom App**
3. App Name: **Aria** (or your choice)
4. Enable permissions:

```
Messaging:
  ✅ im:message
  ✅ im:message:send_as_bot
  ✅ im:resource
Documents:
  ✅ docx:document
Bitable:
  ✅ bitable:app
Contact:
  ✅ contact:user.id:readonly
```

5. **Event Subscriptions** → Add:
   - `im.message.receive_v1`
   - `card.action.trigger`

6. Set webhook URL (after Cloudflare tunnel is running):
   `https://aria.your-domain.com/webhook/lark`

### Step 5 — Cloudflare Tunnel

```bash
# Login (one-time)
cloudflared tunnel login

# Create tunnel
cloudflared tunnel create openclaw

# Edit config with your tunnel ID
nano config/tunnel.yaml
cp config/tunnel.yaml ~/.cloudflared/config.yml

# Install as system service
sudo cloudflared service install
sudo systemctl start cloudflared

# Verify
cloudflared tunnel info openclaw
```

**No domain? Use quick tunnel for testing:**
```bash
cloudflared tunnel --url http://localhost:8080
# Updates Lark webhook URL with the displayed *.trycloudflare.com URL
```

### Step 6 — Start Services

```bash
sudo systemctl start piclaw
sudo systemctl status piclaw

# Watch live logs
tail -f /data/openclaw/logs/webhook.log
```

---

## Phase-by-Phase Rollout

### ✅ Phase 1 (Start Here)
- Lark bot responds to messages
- Daily French questions card at 8 AM
- Answer grading + feedback

### 🔲 Phase 2
- Upload resume → auto-parsed → profile confirmed
- Job matching cards (Mon/Wed/Fri)

### 🔲 Phase 3
- Cover letter drafting on "Apply" tap
- Job tracker in Lark Bitable

### 🔲 Phase 4
- French notes auto-compiled to Lark Doc
- Weekly Sunday report card

---

## File Structure

```
piclaw/
├── config/
│   ├── openclaw.config.yaml     # Main agent config
│   ├── .env.template            # Copy → ~/.openclaw/.env
│   └── tunnel.yaml              # Cloudflare tunnel config
├── skills/
│   ├── french_coach.yaml        # French learning skill
│   ├── job_skills.yaml          # Resume parser + job scout
│   └── reporter.yaml            # Weekly report skill
├── memory/
│   ├── MEMORY.md                # Core user memory
│   └── PROGRESS.md              # French progress tracker
├── scripts/
│   ├── setup_pi.sh              # Full Pi installation script
│   └── lark_server.py           # Webhook server
└── README.md                    # This file
```

---

## Cost Estimate (Moonshot API)

| Task | Model | Tokens/run | Cost |
|---|---|---|---|
| Daily French questions | moonshot-v1-8k | ~2K | ~$0.002 |
| Grade answers | moonshot-v1-8k | ~1.5K | ~$0.0015 |
| Job matching (3x/week) | moonshot-v1-128k | ~8K | ~$0.024 |
| Cover letter drafting | moonshot-v1-128k | ~3K | ~$0.009 |
| Weekly report | moonshot-v1-8k | ~2K | ~$0.002 |
| **Monthly total** | | | **~$3–5/month** |

Well within your $10/month target. 🎯

---

## Troubleshooting

**Webhook not receiving events:**
```bash
# Check server is running
sudo systemctl status piclaw
# Check tunnel is up
cloudflared tunnel info openclaw
# Test endpoint
curl -X POST http://localhost:8080/webhook/lark \
  -H "Content-Type: application/json" \
  -d '{"type":"url_verification","challenge":"test"}'
```

**Pi throttling under load:**
```bash
# Check CPU temp
vcgencmd measure_temp
# Should be < 70°C under load
# If higher: add heatsink or reduce cron job frequency
```

**Memory running low:**
```bash
free -h
# Moonshot handles all inference — Pi only needs ~200MB for the agent
# If tight, disable vector search in config
```
