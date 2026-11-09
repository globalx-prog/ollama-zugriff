# 🛡️ Cloudflare Zero Trust Tunnel & Stack-Sicherheit (Handbuch)
## Architektur, Container-Härtung, Verifikation & Rollback-Strategie

> **System:** `clemi-pc` (Host: Ubuntu Linux / Docker Desktop)  
> **Netzwerk:** `ai-network` (Docker Bridge) + Tailscale (`100.x.y.z`)  
> **Stand:** Oktober 2026

---

## 🏛️ 1. Architektur & Routing-Übersicht

Alles läuft über Docker Compose im isolierten Netzwerk `ai-network`, ohne offene WAN-Ports am Router. Das Routing liegt zentral im Cloudflare Zero Trust Dashboard:

```text
Internet / Mobilgeräte
   │ HTTPS (Zero Trust Access / Auth)
   ▼
deine-domain.de (Cloudflare Edge)
   │
   ├── openwebui.deine-domain.de ── CNAME ──► <UUID>.cfargotunnel.com
   │                                                 │
   │                                                 ▼ (Tunnel "openwebui-tunnel")
   │                                           cloudflared (Container, Compose)
   │                                                 │
   │                                                 ▼
   │                                           ai-network (Docker bridge)
   │                                          ├── open-webui:8080 (127.0.0.1:3000)
   │                                          └── searxng:8080    (127.0.0.1:8081)
   │
Host-Systemd (außerhalb Docker):
   ollama serve ── 11434 ──► Gehärtet: Tailscale-only (100.x.y.z) + UFW
   Erreichbar aus open-webui via http://100.x.y.z:11434
```

### Goldene Betriebs-Prinzipien:
1. **Genau EIN cloudflared-Connector:** Option B (Docker) ist aktiv. Option A (systemd-Dienst auf dem Host) muss gestoppt und deaktiviert bleiben (`sudo systemctl disable --now cloudflared`), um Verbindungskonflikte (502/504-Flackern) zu verhindern.
2. **Keine offenen WAN-Ports:** Kein Port-Forwarding im Router.
3. **Loopback-Bindung (`127.0.0.1`):** Open WebUI (`127.0.0.1:3000`) und SearXNG (`127.0.0.1:8081`) lauschen auf dem Host ausschließlich auf Loopback und sind aus dem LAN (`192.168.0.x`) nicht erreichbar.
4. **Remotely Managed Tunnel:** Bei Cloudflare Zero Trust liegt das Hostname-Routing (`openwebui.deine-domain.de` -> `http://open-webui:8080`) ausschließlich im Cloudflare Dashboard.

---

## 🔒 2. Container-Härtung (Security Matrix)

| Komponente | Härtungsmaßnahme | Sicherheits-Nutzen |
| :--- | :--- | :--- |
| **Open WebUI** | `read_only: true` + tmpfs `/tmp` | Read-only Rootfs verhindert persistente Schadsoftware im Container |
| **Open WebUI** | `cap_drop: [ALL]`, `no-new-privileges` | Entzug aller Linux-Kernel-Privilegien |
| **Open WebUI** | `pids_limit: 512` | Schutz vor Fork-Bombs und Denial-of-Service |
| **Open WebUI** | `ENABLE_SIGNUP: "false"` | Registrierung gesperrt; nur autorisierte Accounts möglich |
| **Open WebUI** | `WEBUI_SECRET_KEY` in `.env` (chmod 600) | Statische Session-Keys; verhindert Session-Verlust bei Neustart |
| **Open WebUI** | Persistentes HuggingFace Cache-Volume | Instant-Start in 6 Sekunden statt 502 Bad Gateway beim Boot |
| **SearXNG** | Loopback-only `127.0.0.1:8081` | Nicht über den Cloudflare-Tunnel exponiert (verhindert unauthentifizierte Public-Search-Nutzung) |
| **SearXNG** | Config `:ro` + `FORCE_OWNERSHIP: "false"` | Read-only Config-Mount verhindert Entrypoint-Chown-Fehler |
| **SearXNG** | `cap_drop: [ALL]`, `pids_limit: 256` | Minimale Rechte |
| **cloudflared** | Containerisiert, Mindestrechte | Isoliert im Docker-Netzwerk |
| **Ollama** | Gebunden an Tailscale `100.x.y.z:11434` | Zugriff nur für autorisierte VPN-Clients & Docker-Host |

---

## 🔍 3. Verifikation & Diagnose-Befehle

### Status aller Container prüfen:
```bash
docker ps --filter "name=open-webui" --filter "name=searxng" --filter "name=cloudflared"
```

### Netzwerk-Konnektivität im Docker-Netzwerk:
```bash
# DNS & Erreichbarkeit von SearXNG aus Open WebUI testen:
docker exec -it open-webui curl -s -o /dev/null -w "%{http_code}\n" http://searxng:8080/

# Verbindung von Open WebUI zu Ollama (Tailscale IP) testen:
docker exec -it open-webui curl -s http://100.x.y.z:11434/api/version
```

### Cloudflare Tunnel Logs prüfen:
```bash
docker logs -f cloudflared
```
*(Es sollten `Connection ... registered` Meldungen ohne Reconnect-Schleifen erscheinen).*

---

## 🔄 4. Rollback-Plan (Notfall-Wiederherstellung)

Falls der Docker-Tunnel ausfällt und dringender Zugriff benötigt wird:

### Schnelles Umschalten auf Host-systemd (Option A):
```bash
# 1. Docker-Connector stoppen:
cd /home/clemi/Projekte/LLM/ollama-zugriff/tunnel
docker compose down

# 2. Host-Dienst starten:
sudo systemctl start cloudflared

# 3. Status prüfen:
sudo systemctl status cloudflared
```
*(Hinweis: Im Cloudflare-Dashboard muss der Service in diesem Fall auf `http://localhost:3000` statt `http://open-webui:8080` zeigen).*

### Rückkehr zu Docker Compose (Option B, Normalzustand):
```bash
# 1. Host-Dienst dauerhaft deaktivieren:
sudo systemctl disable --now cloudflared

# 2. Docker-Connector starten:
cd /home/clemi/Projekte/LLM/ollama-zugriff/tunnel
docker compose up -d
```
