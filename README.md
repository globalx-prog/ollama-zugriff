# 🌐 Ollama Zugriff & Web-Stack
## Open WebUI + SearXNG + Cloudflare Zero Trust Tunnel + Tailscale

> **Architektur:** Gehärteter Docker Compose Stack auf Ubuntu Linux  
> **Netzwerk:** `ai-network` (Docker Bridge) + Tailscale (`100.x.y.z`)  
> **Status:** Produktiv aktiv

---

## 🏛️ Architektur-Überblick

```text
                      INTERNET / MOBILGERÄTE
                                │
                ┌───────────────┴───────────────┐
                ▼                               ▼
      Cloudflare Zero Trust            Tailscale Network
    (openwebui.deine-domain.de)       (100.x.y.z:11434)
                │                               │
         (QUIC Outbound)                 (WireGuard VPN)
                ▼                               ▼
       cloudflared (Docker)            clemi-pc (Host)
                │                               │
     ═══════════╪═══════════════════════════════╪══════════════════
                │ Docker-Netzwerk: ai-network   │
                ▼                               ▼
           open-webui ──────────────────► ollama serve (Host)
           (:8080/tcp -> 127.0.0.1:3000)  OLLAMA_BASE_URL (100.x.y.z:11434)
                │
                ▼ (Interne Websuche)
             searxng
           (:8080/tcp -> 127.0.0.1:8081)
```

---

## 📁 Verzeichnis-Struktur (NAS-Standard)

```text
ollama-zugriff/
├── open-webui/                  # Open WebUI Compose & Env (.env chmod 600)
│   ├── docker-compose.yml
│   └── .env.example
├── searxng/                     # SearXNG Compose & Konfiguration
│   ├── docker-compose.yml
│   ├── .env.example
│   └── config/settings.yml
├── tunnel/                      # Cloudflare Tunnel Connector Compose & Token
│   ├── docker-compose.yml
│   └── .env.example
├── docs/                        # Ausführliche Leitfäden & Sicherheitsdokumentation
│   └── cloudflare-tunnel-und-sicherheit.md # Härtung, Container-Limits, Verifikation & Rollback
├── scripts/                     # Laufzeit-Befehle (Status, Neustart)
│   ├── status.sh
│   └── restart.sh
├── setup/                       # Nummerierte Setup-Skripte
│   ├── 01-create-network.sh
│   └── 02-deploy-stack.sh
└── README.md
```

---

## 🚀 Wichtige Befehle

| Zweck | Befehl |
| :--- | :--- |
| **Status aller Container prüfen** | `./scripts/status.sh` |
| **Gesamten Stack neu starten** | `./scripts/restart.sh` |
| **Open WebUI Logs ansehen** | `docker logs -f open-webui` |
| **Cloudflare Tunnel Logs ansehen** | `docker logs -f cloudflared` |
| **SearXNG Logs ansehen** | `docker logs -f searxng` |
| **Sicherheits- & Rollback-Guide** | Siehe [`docs/cloudflare-tunnel-und-sicherheit.md`](docs/cloudflare-tunnel-und-sicherheit.md) |
