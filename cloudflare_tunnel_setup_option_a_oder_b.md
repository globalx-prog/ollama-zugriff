# Cloudflare Tunnel für `nas-clemens.de`: Option A (systemd) oder Option B (Docker)

Diese Anleitung dokumentiert zwei Wege, den Tunnel `openwebui-tunnel`
für Open WebUI (und später SearXNG) zu betreiben. Sie ist die
Ergänzung zu `cloudflare_tunnel_openwebui_nas-clemens_anleitung.md`,
die nur Option B beschreibt.

- **Option A („online“):** `cloudflared` wird per apt auf dem Host
  installiert und läuft als systemd-Dienst.
- **Option B („Docker“):** `cloudflared` läuft als Container in
  Docker Compose im selben Docker-Netzwerk wie die Zielservices.

Beide Optionen nutzen einen **remotely managed** Tunnel: Routing
(öffentlicher Hostname → lokaler Service) und DNS liegen im
Cloudflare-Dashboard; nur der lokale Connector unterscheidet sich.

``` text
             Cloudflare (Dashboard = Routing + DNS)
                        │
                        ▼
                    cloudflared    ← einziger Unterschied: A oder B
                        │
                        ▼
                  lokaler Service
```

## Entscheidung

| | Option A (systemd) | Option B (Docker) |
|---|---|---|
| cloudflared läuft | direkt auf dem Host | in einem Container |
| Update-Weg | `apt upgrade` | neues Image + `docker compose pull` |
| gültiges Service-Ziel im Dashboard | Host-Port: `http://localhost:3000` | Container: `http://open-webui:8080` |
| Namensauflösung | Host-DNS (Docker-Container-Namen sind **nicht** sichtbar) | Docker-DNS (Container-Namen sind sichtbar) |
| Abhängigkeiten | systemd + apt-Repo | Docker (+ Compose) |
| Empfehlung | Host hat systemd, wenige Container | Connector soll mit Compose verwaltet werden, viele Container in einem Netzwerk |

**Ist-Zustand dieses Systems (30.09.2026): Option A ist aktiv**
(systemd, Version 2026.9.3-3, Routing `openwebui.nas-clemens.de →
http://localhost:3000`, extern 200 OK).

Goldene Regel für den Rest der Anleitung:

> **Zu jedem Zeitpunkt darf genau EIN cloudflared-Connector aktiv sein.**
> Ein zweiter Connector (z. B. ein vergessener Container) ist nicht
> fatal, zerlegt aber die Tunnel-Verbindungen und ist die häufigste
> Quelle verwirrender Fehler.

---

## Option A: cloudflared nativ via systemd (empfohlen, aktuell aktiv)

### 2.1 Voraussetzungen

- Debian/Ubuntu (oder Debian-basiert), `systemd` als Init-System
- **kein** cloudflared-Container, der denselben Token benutzt
  (Prüfung s. Kapitel 3)

### 2.2 Installation via apt

```bash
# 1. GPG-Schlüssel des Cloudflare-apt-Repositories
curl -o /etc/apt/trusted.gpg.d/cloudflared.gpg --create-dirs \
  --location "https://pkg.cloudflare.com/cloudflared.gpg"

# 2. apt-Quellliste
cat << 'EOF' | tee /etc/apt/sources.list.d/cloudflared.list
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/trusted.gpg.d/cloudflared.gpg] https://pkg.cloudflare.com/ $(. /etc/os-release && echo "$VERSION_CODENAME") main
EOF

# 3. Paket installieren
apt-get update
apt-get install cloudflared
```

Kontrolle:

```bash
cloudflared --version
dpkg -l cloudflared
```

Ausgabe (30.09.2026): `cloudflared version 2026.9.3-3 (linux amd64)`,
`Installed: 2026.9.3-3`. Das Paket legt das Unit-File
`/etc/systemd/system/cloudflared.service` an.

**Fremde Binaries entfernen** (z. B. ein früher per GitHub-DL
installiertes Binary — ein doppelter `cloudflared` ist die
klassische Stolperfalle):

```bash
ls -l "$(command -v cloudflared)"   # nach apt-Installation: /usr/bin/cloudflared
ls -l /usr/local/bin/cloudflared 2>/dev/null && echo "WARNUNG: zusätzliches Binary!"
rm -f /usr/local/bin/cloudflared    # erst wenn bestätigt, dass es das GitHub-Binary ist
```

**Wichtig:** Die apt-Installation installiert **keine**
Remotely-Managed-Tunnel-Einheit von selbst. Das Unit-File ist leer
(vgl. 2.4). Ohne eigenen Service läuft der Daemon nicht.

### 2.3 Tunnel-TOKEN (nur beim ERSTEN Setup nötig)

1. Cloudflare Zero Trust → Networks → Tunnels:
   - Tunnel `openwebui-tunnel` anlegen
   - Account-ID in der URL notieren: `https://dash.cloudflare.com/<ACCOUNT_ID>`
   - Connector-Code kopieren → das ist der `TOKEN`

2. Token ablegen (cloudflared liest `/etc/cloudflared/token`):

```bash
mkdir -p /etc/cloudflared
echo "<TOKEN>" > /etc/cloudflared/token
chmod 600 /etc/cloudflared/token
chown root:root /etc/cloudflared/token

# Kontrolle (nur Zeilenanfang zeigen, Token bleibt geheim)
head -c 20 /etc/cloudflared/token; echo
```

3. Alt-/Fremdartige Konfigurationsreste prüfen und entfernen:

```bash
ls -la ~/.cloudflared/            # evtl. Reste aus einem früheren manuellen Setup
rm -rf ~/.cloudflared/*           # nur wenn nichts Aktives mehr darauf angewiesen ist
```

```bash
ls -la /etc/cloudflared/config.yml 2>/dev/null
rm -f /etc/cloudflared/config.yml  # nur bei Remote-Managed-Modus löschen
```

`config.yml` mit `tunnels:`/`ingress:`-Sektionen ist nur für den
**local-mode** Daemon sinnvoll (eigene Tunnel-ID + Token). Im
Remote-Managed-Modus (Token, Routing im Dashboard) darf sie nicht
existieren — sie würde sonst das Dashboard-Routing überschreiben.

### 2.4 Systemd-Unit

Das Paket legt `/etc/systemd/system/cloudflared.service` an.
**Kopiere den Ist-Zustand** (1:1 mit dem verifizierten, laufenden System):

```ini
[Unit]
Description=Cloudflare Tunnel
Documentation=https://developers.cloudflare.com/cloudflare-one/connections/connect-networks
After=network.target
Wants=network-online.target

[Service]
ExecStart=/usr/bin/cloudflared --no-autoupdate --origin-request-header X-Tunnel-Name:tunnel-1
User=cloudflared
Group=cloudflared
Restart=on-failure
RestartSec=5

[Install]
WantedBy=default.target
```

Details:

- `--no-autoupdate`: Cloudflareds eigenes Autoupdate ist deaktiviert;
  Updates laufen über `apt upgrade cloudflared`.
- `--origin-request-header X-Tunnel-Name:tunnel-1`: setzt einen
  Request-Header im Origin-Roundtrip (erkennbar im Service-Log).
  Optional, aber harmlos.
- `User=cloudflared` / `Group=cloudflared`: vom apt-Paket angelegt.

Wenn deine Konfiguration abweichen soll, ist das Minimum, das
funktionieren muss:

```ini
[Unit]
Description=Cloudflare Tunnel
After=network.target

[Service]
ExecStart=/usr/bin/cloudflared --no-autoupdate
Restart=on-failure

[Install]
WantedBy=default.target
```

Der Token wird **nicht** in der Unit übergeben, sondern von
cloudflared aus `/etc/cloudflared/token` gelesen (s. 2.3).

### 2.5 Aktivieren, starten, prüfen

```bash
systemctl daemon-reload
systemctl enable cloudflared
systemctl start cloudflared

systemctl is-active cloudflared     # erwartet: active
systemctl status cloudflared --no-pager
journalctl -u cloudflared -f        # Live-Logs
```

Erwartete Log-Zeilen:

```text
Registered tunnel connection
Connection registered: <tunnel-id>
Version: 2026.9.3-3
```

Kritische Fehler-Muster:

| Log-Message | Ursache |
|---|---|
| `invalid token` | Token falsch/veraltet (neu aus Dashboard kopieren) |
| `No valid credentials found` | Token liegt nicht unter `/etc/cloudflared/token` |
| `connection closed with error` (kurz, Neustart) | meist Netzwerk/DNS, unkritisch |
| `duplicate tunnel id` / `already in use` | ein **zweiter Connector** mit demselben Token läuft → Kapitel 4 |

### 2.6 Dashboard: Public Hostname

Zero Trust → Networks → Tunnels → `openwebui-tunnel` →
Public Hostname → `openwebui.nas-clemens.de`:

- Service Type: **HTTP**
- Service: **`http://localhost:3000`** (Open WebUI lauscht auf Host-Port 3000)

Cloudflare registriert den Hostname automatisch per DNS als
`CNAME → <tunnel-id>.cfargotunnel.com`.

**Wichtig:** In Option A ist `localhost` aus der Sicht von
cloudflared der **Host**. Ein Docker-Service-Name wie
`open-webui` (Port 8080) ist vom Host **nicht** auflösbar → 502.

### 2.7 Extern testen + Fehlersuche

```bash
curl -sI https://openwebui.nas-clemens.de    # erwartet: 200 OK
```

Bei `502 Bad Gateway` in dieser Reihenfolge prüfen:

1. `systemctl is-active cloudflared` → läuft der Daemon?
2. `ss -ltn | grep :3000` → lauscht Open WebUI auf dem Host-Port?
3. `docker ps` → Open-WebUI-Container läuft?
4. Dashboard → Public Hostname → Service-Ziel ist `http://localhost:3000`
   und nicht versehentlich `http://open-webui:8080` (das war der
   502-Fall am 30.09.2026: Ziel wurde von Option-B-Syntax auf
   Host-Syntax umgestellt → sofort 200 OK).

### 2.8 SearXNG nachziehen (selber Tunnel)

SearXNG läuft auf der `ai-network`, Host-Port `8888`:

- Dashboard → `openwebui-tunnel` → Public Hostname
  `searxng.nas-clemens.de` → Service `http://localhost:8888`
- **Kein** zweiter Tunnel, **kein** zweiter Connector — ein
  cloudflared bedient beliebig viele Hostnames.

### 2.9 Update-Routine

```bash
apt update && apt upgrade cloudflared
systemctl restart cloudflared
```



---

## Option B: cloudflared als Docker-Container

### 3.1 Voraussetzungen

- Docker (+ Compose v2) auf dem Host
- **Systemd-Dienst stoppen** (wenn Option A je lief), damit nicht
  zwei Connectoren denselben Token nutzen (Prüfung s. Kapitel 3):

```bash
systemctl is-active cloudflared || echo "OK: systemd-Service inaktiv"
systemctl stop cloudflared
systemctl disable cloudflared
```

- Der cloudflared-Container muss an **dasselbe Docker-Netzwerk**
  angehängt werden wie die Zielservices (hier: `ai-network`,
  daran hängen `open-webui` und `searxng`).

### 3.2 Compose-Definition

`docker-compose.yml` (oder `cloudflared`-Sektion in bestehender
Compose-Datei):

```yaml
services:
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: cloudflared
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=<TOKEN>
    networks:
      - ai-network
    restart: unless-stopped

networks:
  ai-network:
    external: true
    name: ai-network
```

Details:

- `TUNNEL_TOKEN`: derselbe Connector-Code wie in `/etc/cloudflared/token`.
- `--no-autoupdate`: Image-Updates bewusst über
  `docker compose pull` statt automatisch.
- `external: true`: das Netzwerk existiert bereits
  (wird von den App-Compose-Dateien angelegt).
- **Nicht** `ports:` mappen — cloudflared verbindet nur ausgehend
  zu Cloudflare (Outbound-UDP/TCP/443).

Starten:

```bash
docker compose up -d cloudflared
docker logs -f cloudflared
```

Erwartete Log-Zeilen (wie Option A): `Registered tunnel
connection`, `Connection registered: <tunnel-id>`.



### 3.3 Dashboard: Public Hostname

Gleiche Tunnel, aber jetzt **Container-Targets** (Docker-DNS):

- `openwebui.nas-clemens.de` → Service **`http://open-webui:8080`**
- `searxng.nas-clemens.de` → Service **`http://searxng:8080`**

(Innere Container-Ports gemäß den jeweiligen Compose-Files —
nicht die Host-Publish-Ports 3000/8888.)

Wichtig: Die Host-Publish-Ports (3000/8888) müssen in Option B
**nicht** weiter exponiert sein; wer will, kann die
`ports:`-Zeilen der App-Container danach aus Compose entfernen
(Host-Port ist dann nur noch für lokale Tests erreichbar,
externer Zugriff läuft komplett durch den Tunnel).

### 3.4 Extern testen + Fehlersuche

```bash
curl -sI https://openwebui.nas-clemens.de    # erwartet: 200 OK
```

- `502` + Dashboard-Ziel `http://localhost:3000`: Target aus
  Option-A-Syntax — im Tunnel-Connector (Container) ist
  `localhost` das Cloudflared-Container-Interne, nicht der Host.
  → Ziel auf `http://open-webui:8080` umstellen.
- `502` + `http://open-webui:8080`: Container-Name nicht
  auflösbar → Netzwerk prüfen:

```bash
docker network inspect ai-network --format '{{range .Containers}}{{.Name}} {{end}}'
docker exec cloudflared getent hosts open-webui
docker exec open-webui curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/health
```

### 3.5 Aufräumen

```bash
docker compose down          # (oder: docker rm -f cloudflared)
docker rmi cloudflare/cloudflared:latest   # optional
```

Zurück zu Option A: Token/Unit existieren unter
`/etc/cloudflared/token` bzw. `cloudflared.service` weiter —
einfach `systemctl enable --now cloudflared`, **und** im
Dashboard die Targets von `http://<service>:<port>` auf
`http://localhost:<host-port>` zurückstellen.


---

## Kapitel 4: Duplikate vermeiden (KERN-KAPITEL)

**Regel:** Pro Token (d. h. pro Tunnel) darf genau **ein**
cloudflared-Connector aktiv sein. Zwei aktive Connectoren mit
demselben Token:

- teilen sich die Edge-Verbindungen unvorhersehbar
- erzeugen `502`/`504`-Ausfälle und Log-Einträge wie
  `duplicate tunnel id` / `already in use` / `connection
  closed` — oft **ohne** klare Fehlermeldung
- sind nach Neustarts/Updates die häufigste Fehlerquelle, weil
  z. B. `docker compose up` und `systemctl enable` beide
  automatisch starten (`restart: unless-stopped` /
  `WantedBy=default.target`)

Der Tunnel **im Dashboard** kann beliebig viele Public Hostnames
haben — nur der lokale Connector ist „ein pro Token“.
Mehrzeitservices (Open WebUI + SearXNG + …) → **ein** Connector,
mehrere Hostnames.

### 4.1 Vor JEDEM Setup: Ist etwas bereits aktiv?

```bash
# 1) Natives systemd
systemctl is-active cloudflared && echo "AKTIV: systemd-Service"

# 2) Docker-Container (alle, die cloudflared laufen lassen)
docker ps -a --filter "name=cloudflared" \
  --format '{{.Names}}: {{.Status}}'

# 3) JEDER laufende cloudflared-Prozess egal wie gestartet
#    (deckt auch Compose-Container mit anderen Namen ab!)
pgrep -a cloudflared || echo "kein cloudflared-Prozess"
```

Ergebnis-Beurteilung:

- `pgrep` zeigt **nichts** → freie Bahn, Option A oder B starten.
- `pgrep` zeigt **`/usr/bin/cloudflared`** → Option A läuft.
  Vor Option B: `systemctl stop cloudflared && systemctl disable cloudflared`.
- `pgrep` zeigt **`/usr/bin/dockerd`**-gesteuerte PID (oder
  `cloudflared ... tunnel run` ohne systemd) → Container/andere
  Instanz läuft. Vor Option A: `docker rm -f <name>` bzw.
  `docker compose down`.

### 4.2 Vor JEDEM Start: gegenseitig ausschließen

**Option A starten** (sicher):

```bash
docker ps -a --format '{{.Names}}' | grep -i cloudflared \
  && docker rm -f $(docker ps -a --format '{{.Names}}' | grep -i cloudflared)
pgrep -a cloudflared || echo "OK: kein cloudflared-Connector aktiv"

systemctl daemon-reload
systemctl enable --now cloudflared
systemctl is-active cloudflared    # erwartet: active
```

**Option B starten** (sicher):

```bash
systemctl is-active cloudflared \
  && (systemctl stop cloudflared && systemctl disable cloudflared && echo "systemd gestoppt+deaktiviert")
pgrep -a cloudflared || echo "OK: kein cloudflared-Connector aktiv"

docker compose up -d cloudflared
docker ps --filter "name=cloudflared"
```

### 4.3 Nach Updates / Reboots / „es ging doch noch gestern"

```bash
pgrep -a cloudflared        # wer läuft genau jetzt?
systemctl is-active cloudflared
docker ps --filter "name=cloudflared"
curl -sI https://openwebui.nas-clemens.de   # 200? 502?
```

Typische Duplikat-Symptome:

| Symptom | wahrscheinliche Ursache |
|---|---|
| `502`/`504` kommt und geht, Logs flackern `connected`/`disconnected` | zwei Connectoren kämpfen um dieselben Edge-Connections |
| `journalctl -u cloudflared`: `duplicate tunnel id` / `already in use` | Container läuft parallel zu systemd (oder umgekehrt) |
| nach `docker compose up`: Host-Dienst startet wieder | `systemctl disable` beim Wechsel nach Option B vergessen |
| nach Reboot: doppelte Anmeldung | `restart: unless-stopped` UND `WantedBy=default.target` gleichzeitig |

Abhilfe: `pgrep -a cloudflared` → alles außer der gewählten
Option stoppen (`systemctl stop` bzw. `docker rm -f`), dann
**dauerhaft** inaktiv schalten (`systemctl disable` /
`docker compose down`).


---

## Kapitel 5: Kurz-Referenz (Cheatsheet)

```bash
# ---------- Status: wer läuft gerade? ----------
pgrep -a cloudflared
systemctl is-active cloudflared
docker ps --filter "name=cloudflared"

# ---------- Option A ----------
systemctl enable --now cloudflared          # starten
systemctl stop cloudflared && systemctl disable cloudflared  # stoppen+entfernen
journalctl -u cloudflared -f                # Logs
apt update && apt upgrade cloudflared && systemctl restart cloudflared  # Update

# ---------- Option B ----------
docker compose up -d cloudflared            # starten
docker compose down                         # stoppen+entfernen
docker logs -f cloudflared                  # Logs
docker compose pull cloudflared && docker compose up -d cloudflared     # Update

# ---------- Extern ----------
curl -sI https://openwebui.nas-clemens.de   # 200 OK erwartet
```

Dashboard-Ziele je nach Option:

| Hostname | Option A (systemd) | Option B (Docker) |
|---|---|---|
| `openwebui.nas-clemens.de` | `http://localhost:3000` | `http://open-webui:8080` |
| `searxng.nas-clemens.de` | `http://localhost:8888` | `http://searxng:8080` |

**Merksatz:** `localhost` heißt *Host* im systemd-Daemon, aber
*Container* im Docker-Connector — bei der Option-Umstellung also
**immer** Dashboard-Ziele **und** exakt einen aktiven Connector.

---

## Anhang: Ist-Zustand dieses Systems (30.09.2026)

- **Option A aktiv:** `cloudflared 2026.9.3-3` via apt,
  `/etc/systemd/system/cloudflared.service` (s. 2.4),
  Token in `/etc/cloudflared/token` (600, root).
- **Option B geräumt:** Container/Bild `sharp_bell` +
  `cloudflare/cloudflared` entfernt, kein cloudflared-Container
  mehr vorhanden.
- **Aufräumen:** altes `~/.cloudflared/` (inkl. `cert.pem`,
  `config.yml`) und doppeltes Binary `/usr/local/bin/cloudflared`
  gelöscht.
- **Routing (Dashboard):** `openwebui.nas-clemens.de →
  http://localhost:3000` (war `http://open-webui:8080` → das
  verursachte den 502, bis auf Host-Syntax umgestellt),
  `searxng.nas-clemens.de → http://localhost:8888`.
- **Geprüft:** extern `200 OK`, Daemon `active`,
  `Registered tunnel connection` in den Logs.

Historie & Dashboard-Schritte: siehe
`cloudflare_tunnel_openwebui_nas-clemens_anleitung.md` (dort nur
Option B).