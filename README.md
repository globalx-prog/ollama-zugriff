# Private & Hardened AI Stack: Ollama + Open WebUI + SearXNG + Cloudflare Tunnel + Tailscale

A production-ready, hardened local AI stack running on Ubuntu / Docker Desktop (WSL2), accessible both securely via **Cloudflare Zero Trust Tunnel** and internally via **Tailscale**.

---

## 🏛 Architecture Overview

```
                      INTERNET / CLIENTS
                              │
               ┌──────────────┴──────────────┐
               ▼                             ▼
     Cloudflare Zero Trust            Tailscale Network
   (openwebui.yourdomain.de)        (100.x.y.z Tailnet IP)
               │                             │
        (QUIC Outbound)                (WireGuard VPN)
               ▼                             ▼
       cloudflared (Docker)          clemi-pc (Host / WSL2)
               │                             │
    ═══════════╪═════════════════════════════╪══════════════════
               │ Docker Network: ai-network  │
               ▼                             ▼
          open-webui ──────────────────► ollama serve (Host)
          (:8080/tcp)      OLLAMA_BASE_URL (100.102.224.36:11434)
               │
               ▼ (Internal Search)
            searxng
          (:8080/tcp)
```

---

## 🔒 Security & Hardening Features

| Component | Hardening Measure | Benefit |
|---|---|---|
| **All Services** | No Router Port Forwarding | Zero open WAN ports on the home router. |
| **Open WebUI** | Loopback binding `127.0.0.1:3000` | Inaccessible from local LAN (`192.168.0.x`). |
| **Open WebUI** | `read_only: true` with tmpfs `/tmp` | Read-only container rootfs prevents persistent malware. |
| **Open WebUI** | Persistent model cache in volume | HuggingFace embedding cache (`HF_HOME`) stored in volume `open-webui`, enabling instant 6-second startups without 502 Bad Gateway delays. |
| **Open WebUI** | `cap_drop: [ALL]`, `no-new-privileges` | Complete Linux privilege stripping. |
| **Open WebUI** | `pids_limit: 512` | Protection against process exhaustion / fork bombs. |
| **Open WebUI** | `WEBUI_SECRET_KEY` in `.env` (chmod 600) | Static session JWT signing, prevents session loss on recreation. |
| **Open WebUI** | `ENABLE_SIGNUP: "false"` | Disables public registrations; only pre-existing admin can log in. |
| **SearXNG** | Loopback binding `127.0.0.1:8081` | Protected from WAN and LAN; only reachable locally and via internal Docker DNS. |
| **SearXNG** | Not exposed over Cloudflare Tunnel | Prevents abuse as an open unauthenticated public search engine. |
| **SearXNG** | `cap_drop: [ALL]`, `no-new-privileges`, `pids_limit: 256` | Minimal privileges, locked process limits. |
| **SearXNG** | Config mounted `:ro` + `FORCE_OWNERSHIP="false"` | Immutable configuration directory. |
| **Ollama** | Bound strictly to Tailscale IP (`100.102.224.36:11434`) | LAN-wide unauthenticated API access closed. |
| **Ollama CLI** | `export OLLAMA_HOST=100.102.224.36:11434` in `~/.bashrc` | `ollama list`, `ollama pull` work seamlessly from terminal. |
| **cloudflared** | Docker container, `cap_drop: [ALL]`, `no-new-privileges` | Host systemd service disabled, single connector strictly enforced. |
| **All Containers**| Version-pinned images | Reproducible, stable builds without unexpected `:latest` or `:main` breaking changes. |
| **All Containers**| `restart: unless-stopped` | Automatic startup upon system / Docker boot. |

---

## 📁 Repository Structure

```
.
├── open-webui/
│   ├── docker-compose.yml       # Open WebUI stack definition (pinned v0.11.4 + hardened)
│   ├── .env.example             # Template for OWUI version & secrets
│   └── .env                     # (Ignored) Actual secrets
├── searxng/
│   ├── docker-compose.yml       # SearXNG stack definition (pinned + hardened)
│   ├── .env.example             # Template for SearXNG version pin
│   ├── .env                     # (Ignored) Actual environment
│   └── config/
│       ├── settings.example.yml # Template for SearXNG settings
│       └── settings.yml         # (Ignored) Actual instance settings
├── tunnel/
│   ├── docker-compose.yml       # Cloudflare Tunnel connector stack
│   ├── .env.example             # Template for Tunnel token
│   └── .env                     # (Ignored) Actual Cloudflare Tunnel token
├── cloudflare_tunnel_safety_sicherung.md # Comprehensive German documentation & rollback guides
├── cloudflare_tunnel_setup_option_a_oder_b.md # Architecture rationale (Option A vs B)
├── .gitignore                   # Strict exclusions for all credentials & keys
└── README.md                    # Project documentation
```

---

## 🚀 Quickstart & Setup

### 1. Prerequisites
- Docker Engine & Docker Compose v2 (or Docker Desktop with WSL2)
- Ollama installed on the host system
- Tailscale installed and authenticated
- Cloudflare account with a Zero Trust Tunnel configured

### 2. Network Setup
Create the shared Docker bridge network if not already present:
```bash
docker network create ai-network
```

### 3. Configure Environments
For each service, copy the `.env.example` file and configure your values:

```bash
# Open WebUI
cd open-webui
cp .env.example .env
chmod 600 .env
sed -i "s/change-this-to-a-secure-random-32-byte-hex-string/$(openssl rand -hex 32)/" .env

# SearXNG
cd ../searxng
cp .env.example .env
cp config/settings.example.yml config/settings.yml
chmod 600 config/settings.yml
sed -i "s/CHANGE_ME_TO_A_RANDOM_SECRET_KEY/$(openssl rand -hex 32)/" config/settings.yml

# Cloudflare Tunnel
cd ../tunnel
cp .env.example .env
chmod 600 .env
# Paste your Cloudflare Zero Trust Tunnel token into .env:
# nano .env
```

### 4. Configure Host Ollama Service & CLI
Edit `/etc/systemd/system/ollama.service`:
```ini
[Service]
Environment="OLLAMA_MODELS=/home/models"
Environment="OLLAMA_HOST=100.102.224.36:11434"
```
Reload and restart Ollama:
```bash
sudo systemctl daemon-reload && sudo systemctl restart ollama
```

Add the Ollama host environment variable to `~/.bashrc` so CLI commands work:
```bash
echo 'export OLLAMA_HOST=100.102.224.36:11434' >> ~/.bashrc
source ~/.bashrc
```

### 5. Start the Stacks
Start the services in the following order:

```bash
# Start SearXNG
cd /path/to/repo/searxng && docker compose up -d

# Start Open WebUI
cd ../open-webui && docker compose up -d

# Start Cloudflare Tunnel
cd ../tunnel && docker compose up -d
```

> [!NOTE]
> **Existing Open WebUI Volumes & Connections:**
> If migrating an existing Open WebUI volume where Ollama connections were previously saved in the WebUI, ensure the Ollama URL in **Admin Panel ➔ Settings ➔ Connections ➔ Ollama API** is set to `http://100.102.224.36:11434` (Open WebUI's database config takes precedence over environment variables).

---

## 🌐 Dual Access Setup: Cloudflare + Tailscale

### Access via Cloudflare Tunnel
In the Cloudflare Zero Trust Dashboard:
- **Tunnel:** Point `openwebui.yourdomain.de` to `http://open-webui:8080` (HTTP).
- *SearXNG is deliberately NOT mapped to a public hostname.*

### Extra Security Without Tailscale (Cloudflare Access Zero Trust)
To secure Open WebUI from any browser without needing Tailscale installed:
1. Go to **Cloudflare Zero Trust Dashboard ➔ Access ➔ Applications**.
2. Add a **Self-hosted** application for `openwebui.yourdomain.de`.
3. Create an **Allow** policy requiring Email OTP verification for your email address.
4. *(Optional)* Enable **2FA (TOTP)** directly in Open WebUI under *Settings ➔ Account ➔ Enable 2FA*.

### Access via Tailscale Serve (Local & Private)
Allow authorized Tailnet nodes to access Open WebUI directly:
```bash
# Set non-root operator
sudo tailscale set --operator=$USER

# Serve Open WebUI on standard HTTPS port
tailscale serve --bg --https=443 3000

# Optional: Serve SearXNG on port 8443
tailscale serve --bg --https=8443 8081
```

Now you can open:
- `https://your-node.<tailnet>.ts.net/` → Open WebUI
- `https://your-node.<tailnet>.ts.net:8443/` → SearXNG

---

## 💾 Backup Routine

An automated backup script `backup-ai-stack.sh` exports:
1. All Compose definitions and non-secret configuration files.
2. The `open-webui` Docker named volume (containing chats, users, and vector cache).
3. The host Ollama systemd unit.

### Manual Run
```bash
~/bin/backup-ai-stack.sh
```

### Cron Schedule (Daily at 03:00 AM)
```cron
0 3 * * * ~/bin/backup-ai-stack.sh >> ~/backup-ai-stack.log 2>&1
```

---

## 🔍 Verification Commands

```bash
# 1. Verify container status and health
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'

# 2. Verify container isolation (must fail / connection refused from LAN)
curl -s --max-time 3 http://192.168.0.172:3000/ || echo "OWUI LAN blocked"
curl -s --max-time 3 http://192.168.0.172:8081/ || echo "SearXNG LAN blocked"
curl -s --max-time 3 http://192.168.0.172:11434/api/tags || echo "Ollama LAN blocked"

# 3. Test inter-container communication
docker exec open-webui curl -s http://100.102.224.36:11434/api/version
docker exec open-webui curl -s 'http://searxng:8080/search?q=test&format=json' | head -c 100

# 4. Test external tunnel
curl -sI https://openwebui.yourdomain.de | head -n 5
```
