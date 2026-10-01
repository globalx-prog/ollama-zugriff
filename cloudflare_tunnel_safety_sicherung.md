# Cloudflare Tunnel + Open WebUI + SearXNG — Migration auf Docker Compose, Sicherheits-Härtung & Rollback

> Stand: 01.10.2026 · System: `clemi-pc` (192.168.0.172, Tailscale 100.102.224.36) · Docker **Desktop** (VM, Context `desktop-linux`)
>
> Alle in dieser Anleitung vermerkten Werte (IPs, Versionen, Volume-Namen) wurden am 01.10.2026 **live auf diesem System verifiziert**.
> Backup der alten Konfiguration: `backup/20261001_1257/` (inspect-JSONs, Units, settings, ss/dns-Referenz).

---

## 1. Ziel

Alles läuft über Docker Compose, keine offenen WAN-Ports, Routing zentral im Cloudflare-Dashboard:

```text
Internet
   │ HTTPS
   ▼
nas-clemens.de (Cloudflare)
   │
   ├── openwebui.nas-clemens.de ── CNAME ──► 9a04a73f-…-0e2f21cde841.cfargotunnel.com
   └── searxng.nas-clemens.de     ── CNAME ──► 9a04a73f-…-0e2f21cde841.cfargotunnel.com
                                                       │
                                                       ▼ (Tunnel "openwebui-tunnel",
                                                         remotely managed, UUID
                                                         9a04a73f-9ee2-42a7-a49f-0e2f21cde841)
                                                cloudflared (Container, Compose)
                                                       │
                                                       ▼
                                                 ai-network (Docker bridge)
                                                ├── open-webui:8080
                                                └── searxng:8080

Host-Systemd (außerhalb Docker):
   ollama serve  ── 11434 ──► gehärtet: Tailscale-only (100.102.224.36) + UFW
   erreichbar aus open-webui via http://100.102.224.36:11434
```

**Prinzipien**

1. **Genau EIN cloudflared-Connector zu jedem Zeitpunkt.** systemd-Option A muss gestoppt **und deaktiviert** sein, bevor der Container startet — sonst 502/504-Flackern.
2. **Nichts auf `0.0.0.0` lauschen**, was nicht muss. Open WebUI + SearXNG: nur `127.0.0.1`. Ollama: nur Tailscale-Interface (+ UFW als zweite Wall).
3. **Keine Doppelkonfiguration:** Bei einem remotely managed Tunnel liegt das Routing (Hostname → Service) **ausschließlich im Cloudflare-Dashboard**. Die `docker-compose.yml` des Tunnels startet nur den Connector.

---

## 2. Ist-Zustand (live verifiziert, 01.10.2026)

| Komponente | Zustand | Details |
|---|---|---|
| cloudflared | **systemd, `active` + `enabled`** | `/etc/systemd/system/cloudflared.service` (Kopie in `backup/20261001_1257/systemd/`), `--token-file /etc/cloudflared/token` (600, root), Version 2026.9.3-3 |
| open-webui | **Container via `docker run`** (keine Compose-Labels) | `ghcr.io/open-webui/open-webui:main`, Port **`0.0.0.0:3000`→8080**, Named Volume `open-webui` (~1,1 GB), `OLLAMA_BASE_URL=http://host.docker.internal:11434`, an `ai-network` + `bridge` |
| searxng | **Container via `docker run`** (keine Compose-Labels) | `searxng/searxng:latest`, Port **`0.0.0.0:8081`→8080**, Bind `/home/clemi/Projekte/LLM/searxng → /etc/searxng` (rw), Cache in **anonymem** (flüchtigem) Volume |
| ollama | **Host-Systemd** (`active`, `enabled`) | `/etc/systemd/system/ollama.service`, `Environment="OLLAMA_HOST=0.0.0.0:11434"`, `OLLAMA_MODELS=/home/models`, Version 0.34.4 |
| Tunnel-Routing (Dashboard) | `openwebui.nas-clemens.de → http://localhost:3000` | extern 200 OK (Host-Port, weil Option A) |
| DNS | `openwebui.nas-clemens.de` → CNAME `…cfargotunnel.com` ✅ | `searxng.nas-clemens.de` → **nicht vorhanden** |
| Docker | **Docker Desktop** (VM), Context `desktop-linux` | `host.docker.internal` = VM-Gateway (192.168.65.254, nur in der VM sichtbar) |
| Tailscale | Host `100.102.224.36`, VM `100.107.76.120` (clemi-pc-docker-desktop) | |
| UFW | Status **unverifiziert** (sudo nicht in der Analyse-Phase ausgeführt) | Vorgehen in Abschnitt 7.3 |

**Erreichbarkeits-Test Ollama aus dem open-webui-Container** (live, Ollama noch `0.0.0.0:11434`):

| Ziel | Ergebnis | Bedeutung |
|---|---|---|
| `host.docker.internal:11434` | ✅ `{"version":"0.34.4"}` | funktioniert **nur**, solange Ollama auch auf dem Interface lauscht, auf das die VM-Brücke trifft |
| `100.102.224.36:11434` (Tailscale) | ✅ `{"version":"0.34.4"}` | Tailscale-IP ist vom Container direkt erreichbar → Grundlage der Härtung |
| `192.168.0.172:11434` (LAN) | ✅ `{"version":"0.34.4"}` | ← **das ist die Sicherheitslücke** (LAN-weit offen, kein Auth) |
| `127.0.0.1:11434` | ❌ Connection refused | 127.0.0.1 im Container = Container-Loopback, irrelevant |

**Konsequenz (Lockstep):** `host.docker.internal` zeigt auf das **VM-Gateway**, nicht auf die Tailscale-IP. Bindet man Ollama **nur** auf `100.102.224.36`, funktioniert `host.docker.internal` **nicht mehr** — deshalb zeigt `open-webui/docker-compose.yml` ab dieser Migration auf `http://100.102.224.36:11434` (live verifiziert erreichbar).

**Namen-/Port-Konflikt — wichtigster Stolperstein der Migration:**
Die alten Container heißen exakt `open-webui` bzw. `searxng` und belegen dieselben Ports. `docker compose up -d` **scheitert**, solange sie existieren. Deshalb Schritt 4.3/4.4 (stoppen **und** entfernen) **vor** dem `up`. Die alten Container sind reine `docker run`-Container (keine Compose-Labels) — sie können **nicht** per `docker compose down` verwaltet werden; `docker stop` + `docker rm` ist der einzige saubere Weg. **Daten bleiben erhalten**, da sie im Named Volume `open-webui` liegen (nicht im Container).

---

## 3. Neues Dateilayout

```text
cloudflare/
├── tunnel/
│   ├── docker-compose.yml        # cloudflared-Connector (externes Netz ai-network)
│   └── .env                      # TUNNEL_TOKEN=  ← MUST ERST FÜLLEN (Schritt 4.1)
├── open-webui/
│   └── docker-compose.yml        # 127.0.0.1:3000→8080, Volume external, ai-network
├── searxng/
│   ├── docker-compose.yml        # 127.0.0.1:8081→8080, config :ro, FORCE_OWNERSHIP=false
│   └── config/settings.yml       # 1:1 aus dem alten Config-Verzeichnis + public_instance:false
└── backup/20261001_1257/         # ALLE Rollback-Daten (s. u.)
```

| Compose-Stack | Container | Port (neuer Zustand) | Netzwerk | Volumes |
|---|---|---|---|---|
| `cloudflare-tunnel` | `cloudflared` | — (nur ausgehend) | `ai-network` (external) | — |
| `open-webui` | `open-webui` | `127.0.0.1:3000`→8080 | `ai-network` (external) | `open-webui` (external, bestehend) |
| `searxng` | `searxng` | `127.0.0.1:8081`→8080 | `ai-network` (external) | `searxng_searxng-cache` (neu, flüchtig) |

**SearXNG-Config-Vergleich (alt vs. neu, live geprüft):**

| | alt (`/home/clemi/Projekte/LLM/searxng`) | neu (`cloudflare/searxng/config/settings.yml`) |
|---|---|---|
| `secret_key` | `59bb2f38…89f8a` | unverändert (gleicher Key → Sessions/Validierung stabil) |
| `image_proxy` | `true` | `true` |
| `public_instance` | (nicht gesetzt) | `false` (explizit, private Instanz) |
| `search.formats` | html, json | html, json |

→ Neue Config ist eine strikte Obermenge; kein Feature geht verloren.

**`FORCE_OWNERSHIP=false` (SearXNG):** Der offizielle Image-Entrypoint (`/usr/local/searxng/entrypoint.sh`) führt `chown -R searxng:searxng /etc/searxng` aus. Bei dem neuen read-only-Mount (`:ro`) schlägt das mit `Read-only file system` fehl. Die Variable ist eine offizielle Env des Entrypoints (Default `true`); auf `false` gesetzt wird das chown übersprungen. **Live-geprüft:** Der Fehler ist nicht fatal (Health-Check lieferte 200 auch ohne die Variable), die Variable hält die Logs aber sauber und eliminiert die Fehlermeldung.

**Sicherheitsrelevante Compose-Details (Tunnel-Stack):** `cap_drop: ALL`, `cap_add: CHOWN/SETGID/SETUID` (wird von cloudflared für sein eigenes User-Setup benötigt), `security_opt: no-new-privileges:true`.



---

## 4. Migration in 8 Schritten (Reihenfolge ist wichtig!)

> Gesamtdauer ca. 10–15 min. Ausfallfenster für `openwebui.nas-clemens.de`: **nur zwischen Schritt 4.6 und 4.8**
> (alter systemd-Connector gestoppt, neuer Container noch nicht verbunden) — in der Praxis < 1 Minute.
> Alle Befehle in `~/Projekte/LLM/cloudflare`, außer wo anders angegeben.

### Schritt 4.1 — `TUNNEL_TOKEN` eintragen (kann auch am Vortag geschehen)

```bash
cd ~/Projekte/LLM/cloudflare/tunnel
sudo cat /etc/cloudflared/token     # -> Inhalt kopieren (identischer Token wie die laufende Option A)
nano .env                           # -> in die Zeile TUNNEL_TOKEN=... einfügen
chmod 600 .env
# Interpolation prüfen — Token muss im gerenderten Config sichtbar sein (nur lokal):
docker compose config 2>/dev/null | grep -c 'eyJ'   # -> 1 erwartet
```

Alternativ Token-Quelle Cloudflare-Dashboard: *Zero Trust → Networks → Tunnels → `openwebui-tunnel` → ⋯ → Copy token*.

### Schritt 4.2 — Tailscale-IP sichern (für Ollama-Änderung in Schritt 4.7)

```bash
tailscale ip -4          # -> 100.102.224.36 (wird in 4.7 benötigt)
```

**Falls sich die Tailscale-IP je ändern sollte** (z. B. `tailscale up --reset`):
(1) `OLLAMA_HOST` in der Ollama-Unit, (2) `OLLAMA_BASE_URL` in `open-webui/docker-compose.yml`,
(3) UFW-Regel aus Abschnitt 7.3 an der neuen IP ausrichten, (4) OWUI-Stack neu starten.

### Schritt 4.3 — Alten `open-webui`-Container stoppen und entfernen (Namen-/Port-Freiheit)

```bash
docker stop open-webui && docker rm open-webui
```

> Daten sind sicher: sie liegen im Named Volume `open-webui` (existiert weiterhin), nicht im Container.
> Der alte Container hatte `restart: always` — `docker stop` + `docker rm` ist der einzige saubere Weg,
> da er **kein** Compose-Container ist (keine Labels) und daher nicht per `docker compose down` erreichbar ist.

### Schritt 4.4 — Alten `searxng`-Container stoppen und entfernen

```bash
docker stop searxng && docker rm searxng
```

> Der alte SearXNG-Config-Bind-Source `/home/clemi/Projekte/LLM/searxng` bleibt **unverändert auf der Platte**
> (wird nicht angefasst) — die neue Config liegt unter `cloudflare/searxng/config/`.

### Schritt 4.5 — Zwei neue Compose-Stacks starten (Tunnel-Wartung noch NICHT)

```bash
cd ~/Projekte/LLM/cloudflare/open-webui
docker compose up -d
cd ~/Projekte/LLM/cloudflare/searxng
docker compose up -d

# Kontrolle: beide müssen laufen, OWUI wird "healthy"
docker ps --filter name=open-webui --filter name=searxng
curl -s -o /dev/null -w 'OWUI lokal: %{http_code}\n' http://127.0.0.1:3000
curl -s -o /dev/null -w 'SearXNG lokal: %{http_code}\n' http://127.0.0.1:8081/healthz
```

> In diesem Moment ist **`openwebui.nas-clemens.de` immer noch erreichbar** — der alte systemd-cloudflared
> routet weiter auf `http://localhost:3000`, und der neue Container lauscht exakt dort (127.0.0.1:3000).
> Das gilt solange, bis Schritt 4.6 den alten Connector stoppt.

**OWUI↔Ollama-Check (wichtig!):** Der neue OWUI zeigt auf `http://100.102.224.36:11434` (Tailscale).
Solange Ollama noch `0.0.0.0:11434` hat, funktioniert das sofort. Prüfen:

```bash
docker exec open-webui curl -s http://100.102.224.36:11434/api/version
# -> {"version":"0.34.x"} erwartet
```

### Schritt 4.6 — Alten systemd-cloudflared stoppen und dauerhaft deaktivieren

```bash
sudo systemctl stop cloudflared
sudo systemctl disable cloudflared
# Kontrolle: kein cloudflared-Prozess mehr auf dem Host:
pgrep -a cloudflared || echo 'OK: kein cloudflared-Connector aktiv'
```

> **Goldene Regel:** Erst jetzt den alten Connector stoppen, wenn der neue Container (Schritt 4.8)
> starten wird. Zwischen 4.6 und 4.8 ist der Tunnel down (Sekunden).
> `disable` ist zwingend, sonst startet der Dienst nach jedem Reboot wieder → Doppel-Connector!
> (Unit + Token bleiben auf dem System — Rollback in Abschnitt 8.)

### Schritt 4.7 — Ollama härten (Bind auf Tailscale-IP) — Details in Abschnitt 7.1

```bash
TS_IP=$(tailscale ip -4)
sudo sed -i "s/OLLAMA_HOST=0.0.0.0:11434/OLLAMA_HOST=${TS_IP}:11434/" /etc/systemd/system/ollama.service
sudo systemctl daemon-reload && sudo systemctl restart ollama
# Kontrolle: nur noch Tailscale-Interface, NICHT 0.0.0.0, NICHT LAN:
ss -ltn | grep 11434        # -> ${TS_IP}:11434  erwartet (KEIN *:11434)
docker exec open-webui curl -s http://100.102.224.36:11434/api/version   # muss weiter OK sein
```

> Ab hier ist OWUI **dauerhaft** an die Tailscale-IP gekoppelt — deshalb zeigt die
> `open-webui/docker-compose.yml` bereits darauf (Lockstep-Regel s. Abschnitt 2).

### Schritt 4.8 — Tunnel-Compose-Stack starten (neuer Connector)

```bash
cd ~/Projekte/LLM/cloudflare/tunnel
docker compose up -d
sleep 5
docker logs --tail 20 cloudflared
# erwartet: "Registered tunnel connection" (ggf. nach wenigen Sekunden)
```


---

## 5. DNS & Routing (Cloudflare-Dashboard)

Zwei Dinge liegen hier: das **Routing** im Zero-Trust-Portal (welcher Hostname → welcher lokale
Service) und der **DNS-Record** (welcher Name löst auf). Bei einem remotely managed Tunnel zeigt
der CNAME auf die Tunnel-Domain — **kein** A-Record auf die Home-IP.

### 5.1 `openwebui.nas-clemens.de` — Routing umstellen (PFLICHT)

Das ist der **eigentlich notwendige** Schritt. Der bestehende Public Hostname zeigt noch auf
`http://localhost:3000` (Zustand aus Option A, Host-Port). Der neue cloudflared-**Container**
löst `localhost` aber **nicht** so auf — er liegt im Docker-Netz und sieht OWUI nur unter dem
Container-Namen. Umstellen:

1. Zero-Trust-Portal → **Networks → Tunnels → `openwebui-tunnel` → Public Hostname** →
   bei `openwebui.nas-clemens.de` editieren:
   - Service Type: `HTTP`, Address: `open-webui`, Port: `8080`
     → Ziel wird `http://open-webui:8080` (Container-Name im Docker-DNS).
2. Der bestehende **DNS-Record** `openwebui` (CNAME → `…cfargotunnel.com`, Proxied) bleibt
   **unverändert** — er ist schon korrekt.

> **Häufigster Fehler nach der Umstellung:** Das Routing steht noch auf `http://localhost:3000`.
> Extern dann 502, Tunnel-Logs aber „Registered tunnel connection". Ursache: `localhost` im
> Tunnel heißt *das Innere des cloudflared-Containers*, nicht den Host.

### 5.2 `searxng.nas-clemens.de` — öffentliche Exponierung (OPTIONAL — Sicherheitswarnung)

> ⚠️ **Entscheidung erforderlich.** SearXNG 2026.9.25 hat **kein** eingebautes HTTP-Basic-Auth
> und **kein** `ip_whitelist` (im Quellcode + Docs verifiziert). Ein öffentlich erreichbarer
> `searxng.nas-clemens.de` wäre daher ein **offener, nicht-authentifizierter** Suchdienst
> (Scraping, Quota-Verschleiß der Engine-Backends).
>
> **Empfehlung (sicher, Standard dieses Setups):** SearXNG **nicht** ins Internet exponieren.
> Es dient hier als **Backend** für Open WebUIs interne Web-Suche (`http://searxng:8080` im
> Docker-Netz, unbeeinflusst von der Loopback-Port-Bindung) und für den lokalen Browser
> (`127.0.0.1:8081`). → **Diesen Abschnitt 5.2 komplett überspringen** (kein DNS-Record,
> kein Public Hostname).
>
> **Wenn du es trotzdem öffentlich betreiben willst:** erst einen Auth-Proxy dazuschalten
> (z. B. nginx mit Basic-Auth, siehe Abschnitt 7.2), **dann** beides anlegen:
>
> 1. Zero-Trust-Portal → **Networks → Tunnels → `openwebui-tunnel` → Add a public hostname**:
>    - Hostname: `searxng.nas-clemens.de`, Service Type `HTTP`, Address `searxng`, Port `8080`
>      → Ziel `http://searxng:8080`.
> 2. Cloudflare-Dashboard → Zone `nas-clemens.de` → **DNS → Records** → Record anlegen:
>    - Type `CNAME`, Name `searxng`, Target `9a04a73f-9ee2-42a7-a49f-0e2f21cde841.cfargotunnel.com`,
>      Proxy status **Proxied** (orange Cloud), TTL Auto.
>
> Erst wenn der Auth-Proxy läuft: Public Hostname + Proxied-Record aktivieren.

### 5.3 Verifikation nach ~30 s

```bash
# OWUI (Pflicht):
dig +short openwebui.nas-clemens.de    # -> CNAME …cfargotunnel.com
curl -s -o /dev/null -w '%{http_code}\n' https://openwebui.nas-clemens.de   # 200

# SearXNG (NUR wenn 5.2 mit Auth-Proxy aktiviert wurde):
# dig +short searxng.nas-clemens.de    # -> CNAME …cfargotunnel.com
# curl -s -o /dev/null -w '%{http_code}\n' https://searxng.nas-clemens.de   # 200
```


---

## 6. Endverifikation (alle müssen grün sein)

```bash
# 1) Container: 3 laufen, OWUI "healthy"
docker ps --filter name=cloudflared --filter name=open-webui --filter name=searxng

# 2) Genau EIN Connector: kein cloudflared-Prozess außerhalb des Containers
pgrep -a cloudflared || echo 'OK: nur der Container'
# (pgrep findet den Prozess NICHT, weil cloudflared in der Docker-VM läuft —
#  zusätzlich: docker exec cloudflared pgrep -a cloudflared  -> 1 Treffer)

# 3) Keine offenen 0.0.0.0-Ports mehr für die drei Dienste:
ss -ltn | grep -E ':(3000|8081)\b'          # -> leer (nur 127.0.0.1-Bindings, die zeigt ss als 127.0.0.1)
ss -ltn | grep 11434                          # -> 100.102.224.36:11434 (KEIN *:11434)

# 4) Extern:
curl -s -o /dev/null -w 'OWUI extern:  %{http_code}\n' https://openwebui.nas-clemens.de   # 200 (Pflicht)
# SearXNG nur prüfen, wenn Abschnitt 5.2 (Auth-Proxy) aktiviert wurde:
# curl -s -o /dev/null -w 'SearXNG extern: %{http_code}\n' https://searxng.nas-clemens.de  # 200 (optional)

# 5) OWUI <-> Ollama (über Tailscale):
docker exec open-webui curl -s http://100.102.224.36:11434/api/tags | head -c 200

# 6) OWUI interne Web-Suche (Docker-DNS, unbeeinflusst von der Port-Bindung):
docker exec open-webui curl -s 'http://searxng:8080/search?q=test&format=json' | head -c 200

# 7) Tunnel-Logs:
docker logs --tail 10 cloudflared            # "Registered tunnel connection"

---

## 7. Sicherheits-Härtung im Detail

### 7.1 Ollama: von `0.0.0.0:11434` auf Tailscale-only (Empfehlung, Endzustand B)

**Problem (live nachgewiesen):** Ollama (Host-Systemd) lauschte auf `0.0.0.0:11434` und hatte **kein
Authentication** — jedes Gerät im WLAN (192.168.0.x) konnte Modelle nutzen/auslesen (aus dem
OWUI-Container heraus war `192.168.0.172:11434` erreichbar, s. Abschnitt 2).

**Warum nicht einfach `127.0.0.1`?** Ollama läuft **auf dem Host**, OWUI **in der Docker-Desktop-VM**.
`host.docker.internal` (VM-Gateway 192.168.65.254) wird über die VM-Brücke an den Host weitergeleitet —
welches Host-Interface dabei anliegt, hängt vom Ollama-Bind ab. Live-Test (Abschnitt 2) zeigt:
Tailscale-Bind + `OLLAMA_BASE_URL=http://100.102.224.36:11434` funktioniert zuverlässig.

**Änderung** (bereits in Schritt 4.7 ausgeführt; hier die Dokumentation):

```ini
# /etc/systemd/system/ollama.service
Environment="OLLAMA_MODELS=/home/models"
Environment="OLLAMA_HOST=100.102.224.36:11434"
```

```bash
sudo systemctl daemon-reload && sudo systemctl restart ollama
ss -ltn | grep 11434    # -> 100.102.224.36:11434   (vorher: *:11434)
```

**Effekt:**
- ❌ LAN (192.168.0.x) → Port nicht erreichbar
- ❌ WAN → nie erreichbar (Port wird nicht nach außen geleitet)
- ✅ Tailscale-Netz (100.x) → erreichbar — nur eigene Geräte (clemi-pc-docker-desktop, Smartphone etc.)
- ✅ OWUI via `http://100.102.224.36:11434` → erreichbar (live verifiziert)

**Tailscale-IP-Änderung (Lockstep!):** Ändert sich die IP (`tailscale up --reset`), müssen **alle drei**
Stellen angepasst werden: Ollama-Unit, `OLLAMA_BASE_URL` in `open-webui/docker-compose.yml`
(+ `docker compose up -d`), UFW-Regel (7.3). Prüfen mit `tailscale ip -4`.

**Alternative Endzustand A (Fallback, wenn Tailscale-Bind stört):** Ollama bleibt `0.0.0.0:11434`,
Schutz nur über UFW (Abschnitt 7.3: 11434 nur von `192.168.0.0/24` + Tailscale-Subnet). Dann muss
`open-webui/docker-compose.yml` auf `OLLAMA_BASE_URL=http://host.docker.internal:11434` zurück
(Diese Zeile steht dort als Kommentar dokumentiert). Schwächer als B, aber ebenfalls keine
WLAN-Fremdgeräte, wenn UFW aktiv ist.

docker logs --tail 10 cloudflared            # "Registered tunnel connection"
```


### 7.2 SearXNG: Exponierung nur mit Auth

SearXNG 2026.9.25 hat **kein** eingebautes HTTP-Basic-Auth und **kein** `server.ip_whitelist`
(im Quellcode + Docs verifiziert). Schutz der lokalen Instanz = Loopback-Bindung `127.0.0.1:8081`.

- **Nur lokal genutzt (aktuelle Ausrichtung):** fertig — `127.0.0.1:8081` reicht.
- **Trotzdem öffentlich (`searxng.nas-clemens.de`) nutzen:** **erst** einen Auth-Proxy dazuschalten,
  z. B. nginx vor SearXNG mit Basic-Auth oder OAuth-Proxy:

```text
searxng.nas-clemens.de → Tunnel → nginx:8443 (Basic-Auth) → searxng:8080
```

Ohne diesen Schritt wäre der öffentliche Hostname ein **offener Suchdienst** (Scraping-Rate,
IP-Verknüpfung, Quota-Verschleiß der Engine-Backends). Empfehlung (siehe 5.2): SearXNG für dieses
Setup **nicht** öffentlich exponieren — es bleibt Backend für OWUIs Web-Suche und für den lokalen
Browser. Wer es dennoch öffentlich braucht: erst Auth-Proxy, **dann** Public Hostname + Proxied-Record.

### 7.3 UFW (zweite Firewall-Wand, optional aber empfohlen)

Zuvor war der UFW-Status **nicht** verifizierbar (sudo-Prompt in der Analyse-Phase). Prüfen:

```bash
sudo ufw status verbose
```

**Wenn UFW aktiv ist** (Default-Incoming: deny), diese Regeln ergänzen:

```bash
# Ollama: NUR Tailscale-IP (Endzustand B). Bei Endzustand A zusätzlich LAN-Subnet:
sudo ufw allow from 100.64.0.0/10 to any port 11434 proto tcp comment 'Ollama via Tailscale (CGNAT)'
# nur bei Endzustand A:
# sudo ufw allow from 192.168.0.0/24 to any port 11434 proto tcp comment 'Ollama LAN'

# OWUI + SearXNG lauschen nach der Migration nur auf 127.0.0.1 -> keine Regeln nötig.
# (Port 3000/8081 existieren nur als Docker-VM-interner Forward; von außen unerreichbar.)
sudo ufw reload
sudo ufw status numbered   # Kontrolle
```

Hinweis: Tailscale-Verkehr kommt über `tailscale0` (100.64.0.0/10 ist die CGNAT-Tailscale-Bandbreite).
Eine genauere Variante erlaubt nur die konkrete Tailscale-IP des Docker-Desktop-Hosts
(`100.107.76.120`, s. `tailscale status`), ist aber empfindlicher gegenüber IP-Änderungen.

**Wenn UFW deaktiviert ist:** Empfehlung, es zu aktivieren (`sudo ufw enable`) — die Loopback- und
Tailscale-Bindings machen 3000/8081/11434 ohnehin sicher, UFW schützt vor weiteren Host-Diensten.


### 7.4 Open WebUI: Auth & Registrierung

- Port `127.0.0.1:3000` (vorher `0.0.0.0:3000`) → kein LAN-/WAN-Zugriff mehr.
- `ENABLE_SIGNUP: "false"` → keine Neuanmeldungen; der im Named Volume `open-webui` gespeicherte
  Admin-Benutzer bleibt bestehen.
- **Auth bleibt Pflicht:** Die OWUI-Instanz hat ein Benutzer-Konto (DB im Volume). Wer OWUI über den
  Tunnel nutzt, loggt sich dort ein. Zusätzlich kann Cloudflare *Access* (Zero Trust → Access →
  Applications → `openwebui.nas-clemens.de`) ein zweites Auth-Layer voranstellen (SAML/OTP) —
  empfohlen, da OWUI-Sessions sonst die einzige Schutzschicht vor dem Tunnel sind.
- `WEBUI_SECRET_KEY` ist gesetzt (in `open-webui/.env`, chmod 600) — Session-Keys bleiben bei
  Container-Neustarts stabil. Generiert mit `openssl rand -hex 32`.

### 7.5 Container-Härtung (OWUI + SearXNG)

Beide Container laufen mit minimalen Privilegien (umgesetzt 01.10.2026 23:22):

| Container | `cap_drop` | `no-new-privileges` | `pids_limit` | `read_only` |
|---|---|---|---|---|
| `open-webui` | `ALL` | ✅ | 512 | ✅ (tmpfs: `/tmp`, `/app/backend/data/cache`) |
| `searxng` | `ALL` | ✅ | 256 | ❌ (SearXNG schreibt zur Laufzeit in diverse Verzeichnisse) |
| `cloudflared` | `ALL` (+CHOWN,SETGID,SETUID) | ✅ | — | ❌ |

### 7.6 Image-Pinning

Alle Images sind auf exakte Versionen gepinnt (kein `:latest` oder `:main` mehr):

| Container | Vorher | Nachher |
|---|---|---|
| `open-webui` | `:main` (6.5 GB, moving target) | `v0.11.4` (via `OWUI_VERSION` in `.env`) |
| `searxng` | `:latest` | `2026.9.25-12f8b6515` (via `SEARXNG_VERSION` in `.env`) |
| `cloudflared` | `2026.9.3` (war schon gepinnt) | unverändert |

Update-Prozess: Version in `.env` ändern → `docker compose pull` → `docker compose up -d`.

### 7.7 Tailscale Serve (zweiter Zugangsweg)

Tailscale Serve macht OWUI und SearXNG über das Tailnet erreichbar (HTTPS, auto-TLS):

```bash
# Einmalig: Operator setzen (kein sudo mehr nötig danach)
sudo tailscale set --operator=$USER

# OWUI (Port 443 = Default-HTTPS)
tailscale serve --bg --https=443 3000

# SearXNG (Port 8443)
tailscale serve --bg --https=8443 8081

# Status prüfen
tailscale serve status
```

Ergebnis:
- `https://clemi-pc.<tailnet>.ts.net/` → OWUI
- `https://clemi-pc.<tailnet>.ts.net:8443/` → SearXNG

Nur für Geräte im Tailnet erreichbar (z. B. `s24-von-clemens`).

### 7.8 Log-Limits

Docker Desktop VM braucht `/etc/docker/daemon.json` für Log-Rotation:

```bash
# In der Docker Desktop VM ausführen:
wsl -d docker-desktop sh -c 'cat > /etc/docker/daemon.json << EOF
{"log-driver":"json-file","log-opts":{"max-size":"10m","max-file":"3"}}
EOF'
# Danach: Docker Desktop GUI → Restart
```

Wirkt auf neu erstellte Container. Nach Docker-Desktop-Restart + `docker compose up -d`
greifen die Limits für alle Stacks.

### 7.9 Backup-System

Tägliches Backup über `~/bin/backup-ai-stack.sh` (Cron `0 3 * * *`):

- **Gesichert:** Compose-Dateien, Configs, Ollama-Unit, OWUI-Volume (Chatverlauf, DB)
- **NICHT gesichert:** Ollama-Modelle (167 GB, per `ollama pull` wiederherstellbar), `.env`-Dateien (Secrets separat sichern!)
- **Retention:** 7 Tage

```bash
# Manuelles Backup:
~/bin/backup-ai-stack.sh

# Cron einrichten:
(crontab -l 2>/dev/null; echo '0 3 * * * ~/bin/backup-ai-stack.sh >> ~/backup-ai-stack.log 2>&1') | crontab -
```

### 7.10 Zusammenfassung aller Härtungsmaßnahmen

| Maßnahme | Vorher | Nachher |
|---|---|---|
| OWUI Port-Bindung | `0.0.0.0:3000` (LAN + WAN offen) | `127.0.0.1:3000` |
| SearXNG Port-Bindung | `0.0.0.0:8081` (LAN + WAN offen) | `127.0.0.1:8081` |
| Ollama Bind | `0.0.0.0:11434` (LAN + WAN offen, kein Auth) | `100.102.224.36:11434` (nur Tailscale) |
| OWUI ↔ Ollama Route | `host.docker.internal` (VM-Brücke) | `100.102.224.36` (Tailscale, live verifiziert) |
| SearXNG Config-Mount | rw-Bind | `:ro` + `FORCE_OWNERSHIP=false` |
| cloudflared | Host-systemd + Token-File | Container, `cap_drop: ALL`, `no-new-privileges` |
| OWUI Signup | (DB-Default) | `ENABLE_SIGNUP: "false"` explizit |
| OWUI Image | `:main` (moving target) | `v0.11.4` (gepinnt via `.env`) |
| SearXNG Image | `:latest` (moving target) | `2026.9.25-12f8b6515` (gepinnt via `.env`) |
| OWUI Secret Key | leer (Zufall bei Neustart) | `openssl rand -hex 32` in `.env` (chmod 600) |
| OWUI Container-Härtung | keine | `cap_drop: ALL`, `no-new-privileges`, `pids_limit: 512`, `read_only: true` |
| SearXNG Container-Härtung | keine | `cap_drop: ALL`, `no-new-privileges`, `pids_limit: 256` |
| `settings.yml` Permissions | 644 | 600 |
| `.gitignore` | nicht vorhanden | `.env`, `*.key`, `backup/` geschützt |
| Tailscale Serve | nicht konfiguriert | OWUI :443 + SearXNG :8443 via Tailnet HTTPS |
| Backup | keines | Tägliches Backup (Config + OWUI-Daten, 7 Tage Retention) |
| Externe Erreichbarkeit | nur über Cloudflare-Tunnel (OWUI) | OWUI via Tunnel + Tailscale; SearXNG nur lokal + Tailscale |



---

## 8. Rollback auf den alten Zustand

> **Datenverlust-Prüfung vor dem Rollback:** OWUI-Daten liegen im Named Volume `open-webui` und werden
> von Compose und `docker run` **geteilt** — ein Rollback verändert sie nicht.
> SearXNG-Config: die neue `cloudflare/searxng/config/settings.yml` ist eine Obermenge der alten
> (nur `public_instance: false` hinzugekommen) — der alte Config-Pfad
> `/home/clemi/Projekte/LLM/searxng` ist **nie** verändert worden.
> Alle Rollback-Befehle setzen den Ist-Zustand von **01.10.2026 12:57** wieder her
> (Quelle: `backup/20261001_1257/`).

### 8.1 Compose-Stacks stoppen

```bash
cd ~/Projekte/LLM/cloudflare/tunnel    && docker compose down
cd ~/Projekte/LLM/cloudflare/open-webui && docker compose down
cd ~/Projekte/LLM/cloudflare/searxng    && docker compose down
```

> `down` entfernt die Container (Namen `cloudflared`, `open-webui`, `searxng` werden frei),
> lässt aber alle Named Volumes (`open-webui`, `searxng_searxng-cache`) erhalten.

### 8.2 Ollama wieder auf `0.0.0.0` (falls 4.7 ausgeführt wurde)

```bash
sudo sed -i "s/OLLAMA_HOST=100.102.224.36:11434/OLLAMA_HOST=0.0.0.0:11434/" /etc/systemd/system/ollama.service
sudo systemctl daemon-reload && sudo systemctl restart ollama
ss -ltn | grep 11434    # -> *:11434
```

### 8.3 cloudflared systemd-Dienst wieder aktivieren (Option A)

```bash
sudo systemctl enable --now cloudflared
pgrep -a cloudflared            # 1 Treffer
curl -s -o /dev/null -w '%{http_code}\n' https://openwebui.nas-clemens.de   # 200
```

> **Wichtig:** Das Dashboard-Routing muss dazu wieder auf `http://localhost:3000` zeigen,
> wenn der alte OWUI-Container startet (Step 8.4) — das war der Zustand vor der Migration.
> (Unit + Token `/etc/cloudflared/token` sind nicht angefasst worden; Kopie in
> `backup/20261001_1257/systemd/cloudflared.service`.)


### 8.4 Alte OWUI- und SearXNG-Container aus dem Inspect-Backup wiederherstellen

Die originalen `docker run`-Parameter stehen in `backup/20261001_1257/docker/inspect-*.json`.
Laut Inspect liefen beide Container auf dem **Default-Netz `bridge`** und waren zusätzlich per
`docker network connect` an `ai-network` gehängt (beide Netzwerke im Inspect sichtbar).
1:1-Wiederherstellung:

```bash
# --- Open WebUI (wiederhergestellt aus inspect-open-webui.json) ---
docker run -d \
  --name open-webui \
  --restart always \
  -p 3000:8080 \
  -v open-webui:/app/backend/data \
  --add-host=host.docker.internal:host-gateway \
  -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
  ghcr.io/open-webui/open-webui:main
docker network connect ai-network open-webui

# --- SearXNG (wiederhergestellt aus inspect-searxng.json) ---
docker run -d \
  --name searxng \
  -p 8081:8080 \
  -v /home/clemi/Projekte/LLM/searxng:/etc/searxng \
  searxng/searxng:latest
docker network connect ai-network searxng
```

> Abweichungen zum Original (beide harmlos):
> - Der alte SearXNG-Container hatte `restart: no` (Inspect) — hier ebenfalls; bei Bedarf nachrüsten:
>   `docker update --restart unless-stopped searxng`.
> - Der alte SearXNG-Cache lag in einem **anonymen** Volume (flüchtig, kein Datenverlust).
>   Ein frischer `docker run` legt ein neues anonymes Cache-Volume an — wie vorher.

### 8.5 Dashboard/DNS zurückstellen (falls geändert)

- Public Hostname `searxng.nas-clemens.de` im Zero-Trust-Portal löschen (falls angelegt).
- Optional: DNS-Record `searxng` CNAME löschen.
- `openwebui.nas-clemens.de` Routing: `http://localhost:3000` (Option A) — das war der
  Zustand vor der Migration (verifiziert 30.09./01.10.).

### 8.6 Rollback-Verifikation

```bash
docker ps --filter name=open-webui --filter name=searxng   # beide "Up"
pgrep -a cloudflared                                       # 1 Treffer (Host-Binary)
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:3000         # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8081/healthz # 200
curl -s -o /dev/null -w '%{http_code}\n' https://openwebui.nas-clemens.de # 200
ss -ltn | grep -E ':(3000|8081|11434)\b'   # -> wieder *:3000, *:8081, *:11434 (Ist-Zustand)
```

---

## 9. Ausführungs-Checkliste (User Execution Phase)

**Vorbereitung (vor dem Ausfallfenster):**

- [ ] **4.1** `TUNNEL_TOKEN` in `cloudflare/tunnel/.env` eingetragen (aus `sudo cat /etc/cloudflared/token`), `chmod 600 .env`
- [ ] **4.2** `tailscale ip -4` notiert (→ `100.102.224.36`)
- [ ] `docker compose config` in allen drei Stack-Verzeichnissen ohne Fehler ausgeführt

**Migration (kurzes Ausfallfenster, ~10 min):**

- [ ] **4.3** `docker stop open-webui && docker rm open-webui`
- [ ] **4.4** `docker stop searxng && docker rm searxng`
- [ ] **4.5** `docker compose up -d` in `open-webui/` und `searxng/` + lokale 200-Checks + OWUI↔Ollama-Check
- [ ] **4.6** `sudo systemctl stop cloudflared && sudo systemctl disable cloudflared`
- [ ] **4.7** Ollama: `OLLAMA_HOST=100.102.224.36:11434` in der Unit, `daemon-reload`, `restart`, `ss`-Check
- [ ] **4.8** `docker compose up -d` in `tunnel/` + `docker logs cloudflared` → „Registered tunnel connection"
- [ ] **5.1** Cloudflare Zero-Trust: Routing von `openwebui.nas-clemens.de` von `http://localhost:3000`
      auf **`http://open-webui:8080`** umstellen (PFLICHT — sonst 502)
- [ ] **5.2** (optional, nur mit Auth-Proxy) Public Hostname + CNAME `searxng.nas-clemens.de` anlegen
- [ ] **6** Endverifikation (alle 7 Checks grün)

**Härtung (optional, danach):**

- [ ] **7.3** UFW-Regeln für 11434 (Tailscale-only) ergänzen, `sudo ufw reload`
- [ ] **7.4** (optional) Cloudflare Access vor `openwebui.nas-clemens.de` schalten

**Nach 24 h:**

- [ ] Reboot des Hosts testen (alles kommt zurück: `restart: unless-stopped` + `enable`-Zustände)
- [ ] Backup-Ordner `backup/20261001_1257/` 4–8 Wochen aufbewahren, dann archivieren


---

## 10. Troubleshooting

| Symptom | Ursache | Abhilfe |
|---|---|---|
| `docker compose up -d`: „port is already allocated" / „name is already in use" | alter `docker run`-Container (4.3/4.4) noch da | `docker stop <name> && docker rm <name>`, dann erneut `up -d` |
| tunnel-Stack: Logs „no tunnel token provided" | `TUNNEL_TOKEN` in `.env` leer/falsch | Token eintragen (4.1), `docker compose up -d` erneut |
| extern 502/504, Logs flackern „connected/disconnected" | **zwei** cloudflared-Connectoren (systemd + Container) | `pgrep -a cloudflared` + `docker ps --filter name=cloudflared`; `sudo systemctl disable cloudflared` |
| extern 502, Logs aber „Registered tunnel connection" | Dashboard-Ziel falsch (z. B. noch `http://localhost:3000`) | Public Hostname im Zero-Trust-Portal auf `http://open-webui:8080` stellen (Abschnitt 5.1) |
| `searxng.nas-clemens.de` löst DNS nicht auf | CNAME fehlt oder **nicht** Proxied | Record prüfen, orange Cloud setzen (Abschnitt 5.2) |
| OWUI: „Cannot connect to Ollama" nach Schritt 4.7 | Ollama nur noch auf Tailscale-IP; OWUI zeigt aber auf `host.docker.internal` | `OLLAMA_BASE_URL` muss `http://100.102.224.36:11434` sein (ist in der neuen Compose so); `docker compose up -d` in `open-webui/`; IP mit `tailscale ip -4` vergleichen |
| OWUI↔Ollama bricht nach Tailscale-IP-Änderung ab | Lockstep vergessen (7.1) | IP in Unit + Compose + UFW synchron ändern (Liste in 4.2) |
| SearXNG-Logs: „Read-only file system" (chown) | `FORCE_OWNERSHIP` fehlt (nur Kosmetik, nicht fatal) | ist in der neuen Compose gesetzt; Container neu starten |
| nach Reboot: doppelter cloudflared | `systemctl disable` (4.6) vergessen | `sudo systemctl disable cloudflared`; `pgrep -a cloudflared` kontrollieren |
| `openwebui.nas-clemens.de` nach Reboot: kurz 502 | cloudflared-Container langsamer als Cloudflare-Edge | paar Sekunden warten; `docker logs cloudflared` |


---

## Anhang A: Backup-Inhalt `backup/20261001_1257/` (01.10.2026 12:57)

```text
backup/20261001_1257/
├── systemd/
│   ├── cloudflared.service      # Unit der Option A (Rollback 8.3)
│   └── ollama.service           # Ollama-Unit mit OLLAMA_HOST=0.0.0.0:11434 (Rollback 8.2)
├── docker/
│   ├── inspect-open-webui.json  # komplette Config des alten Containers (Rollback 8.4)
│   ├── inspect-searxng.json     # dito
│   └── volumes/open-webui-data  # Dateikopie + open-webui-data.tar.gz (Datensicherung, ~1.1 GB)
├── network/
│   ├── dns-before.txt           # DNS-Referenz (openwebui CNAME vorhanden, searxng nicht)
│   └── ss-ltnp-before.txt       # lauschende Ports vor der Migration
├── searxng-settings-before.yml  # alte SearXNG-Config
├── searxng-dotenv-before.env    # alter SearXNG .env
└── cloudflare_tunnel_setup_option_a_oder_b.md   # (historisch)
```

## Anhang B: Versionen & IDs (live, 01.10.2026)

| Wert | ID |
|---|---|
| Tunnel (remotely managed) | `9a04a73f-9ee2-42a7-a49f-0e2f21cde841` (Name `openwebui-tunnel`) |
| Tunnel-Domain | `9a04a73f-9ee2-42a7-a49f-0e2f21cde841.cfargotunnel.com` |
| cloudflared (Host, Option A) | 2026.9.3-3 |
| cloudflared (Image) | `cloudflare/cloudflared:2026.9.3` |
| open-webui | `ghcr.io/open-webui/open-webui:main` |
| searxng | `searxng/searxng:latest` (= 2026.9.25-12f8b6515) |
| ollama | 0.34.4 |
| Tailscale Host | `100.102.224.36` (clemi-pc) |
| Tailscale Docker-Desktop-VM | `100.107.76.120` (clemi-pc-docker-desktop) |
| LAN | `192.168.0.172` (wlp8s0) |
| Docker-VM-Gateway (`host.docker.internal`) | `192.168.65.254` (nur in der VM sichtbar) |
| Docker-Netzwerk | `ai-network` (bridge, external in allen drei Stacks) |

## Anhang C: Wer braucht was — Zugriffs-Zonen nach der Migration

| Ebene | Wer | Was kann er erreichen |
|---|---|---|
| Cloudflare Edge | Internet | `openwebui.nas-clemens.de`, (optional) `searxng.nas-clemens.de` |
| Tunnel (cloudflared-Container) | nur Cloudflare-Edge | `http://open-webui:8080`, (optional) `http://searxng:8080` |
| Docker-Netz `ai-network` | nur Container | Container-Namen per DNS |
| Host 127.0.0.1 | nur lokale Prozesse | OWUI `:3000`, SearXNG `:8081` |
| Tailscale (100.64.0.0/10) | nur angemeldete Tailscale-Geräte | Ollama `100.102.224.36:11434` |
| LAN (192.168.0.x) | WLAN-Geräte | **nichts** mehr (vorher: OWUI, SearXNG, Ollama) |

