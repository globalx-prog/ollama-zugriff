# 🐳 Docker Native auf Ubuntu: Leitfaden ohne Docker Desktop

> **Ziel:** Entfernen von Docker Desktop (VM-Overhead & GPU-Blockade) und vollständige Nutzung der nativen Linux Docker Engine mit vollem Zugriff auf die **AMD Radeon Pro W7800 (ROCm / /dev/kfd)**.  
> **Inklusive:** Übersichtliche grafische Verwaltung (Portainer Web-UI), Terminal-Dashboard (Lazydocker) und System-Konfiguration.

---

## 📑 Inhaltsverzeichnis
1. [Warum Docker Desktop unter Linux deinstalliert werden sollte](#1-warum-docker-desktop-unter-linux-deinstalliert-werden-sollte)
2. [Schritt-für-Schritt: Docker Desktop sauber deinstallieren](#2-schritt-für-schritt-docker-desktop-sauber-deinstallieren)
3. [Native Docker Engine aktivieren & prüfen](#3-native-docker-engine-aktivieren--prüfen)
4. [Übersichtliche grafische Verwaltung (Portainer Web-UI)](#4-übersichtliche-grafische-verwaltung-portainer-web-ui)
5. [Terminal-Dashboard: Lazydocker (Optional)](#5-terminal-dashboard-lazydocker-optional)
6. [Tägliche CLI-Befehle für Container & Ressourcen](#6-tägliche-cli-befehle-für-container--ressourcen)
7. [Wo und wie werden Einstellungen verwaltet?](#7-wo-und-wie-werden-einstellungen-verwaltet)

---

## 1. Warum Docker Desktop unter Linux deinstalliert werden sollte

Unter Windows und macOS ist Docker Desktop notwendig, weil dort kein nativer Linux-Kernel existiert. Unter **Ubuntu Linux** ist Docker Desktop jedoch fast immer ein Nachteil:

| Eigenschaft | Docker Desktop (VM-Modus) | Native Docker Engine (`docker-ce`) |
| :--- | :--- | :--- |
| **Architektur** | Läuft in einer isolierten QEMU-Virtual-Machine | **Läuft direkt auf dem Linux-Kernel (Bare Metal)** |
| **GPU-Zugriff (ROCm)** | ❌ **Blockiert:** `/dev/kfd` existiert nicht in der VM |  **Voller nativer Zugriff auf AMD W7800** |
| **Ressourcen** | Verbraucht 2–4 GB RAM dauerhaft für die VM | **0 MB Overhead (nur aktive Container brauchen RAM)** |
| **Dateisystem** | Langsamer VM-Mount-Layer | **Volle NVMe-Geschwindigkeit ohne Übersetzung** |
| **Netzwerk** | Virtuelle NAT-Brücke mit Port-Latenzen | **Direkte Host-Netzwerk-Performance** |

---

## 2. Schritt-für-Schritt: Docker Desktop sauber deinstallieren

Deine native Docker Engine (`docker-ce` und `docker-compose-plugin`) ist auf deinem System bereits fertig installiert. Die Deinstallation von Docker Desktop entfernt nur die überflüssige VM.

### Befehl 1: Paket entfernen
```bash
sudo apt remove -y docker-desktop
```

### Befehl 2: VM-Reste und Desktop-Kontext bereinigen
```bash
rm -rf ~/.docker/desktop
rm -f ~/.docker/contexts/meta/*/desktop-linux.json
```

### Befehl 3: Docker-Kontext dauerhaft auf `default` setzen
```bash
docker context use default
```

---

## 3. Native Docker Engine aktivieren & prüfen

### 1. Dienst starten und für Systemstart aktivieren
```bash
sudo systemctl enable --now docker
```

### 2. Status prüfen
```bash
systemctl status docker --no-pager
```
*(Es sollte `Active: active (running)` in grün erscheinen).*

### 3. Test ohne Sudo (Gruppe prüfen)
Dein Benutzer `clemi` ist bereits in der Gruppe `docker`. Prüfe mit:
```bash
docker ps
```
Wenn die Tabelle ohne `permission denied` erscheint, ist alles perfekt eingerichtet!

---

## 4. Übersichtliche grafische Verwaltung (Portainer Web-UI)

Wenn du die visuelle Oberfläche von Docker Desktop (Übersicht über Container, Start/Stop per Mausklick, Live-Logs, RAM-Auslastung) gewohnt bist, ist **Portainer Community Edition (CE)** der weltweite Standard für Linux.

### Portainer mit 1 Befehl installieren:
```bash
# 1. Daten-Speicher für Portainer anlegen
docker volume create portainer_data

# 2. Portainer-Container starten (verbraucht nur ~30 MB RAM)
docker run -d \
  -p 9000:9000 \
  --name portainer \
  --restart=always \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v portainer_data:/data \
  portainer/portainer-ce:latest
```

### Portainer nutzen:
1. Öffne im Browser: `http://localhost:9000`
2. Erstelle beim ersten Aufruf dein Admin-Passwort.
3. Klicke auf **"Get Started"** (Local Environment).

**Was du in Portainer siehst:**
* 📊 **Dashboard:** Alle aktiven und gestoppten Container auf einen Blick.
* 🚦 **Steuerung:** Starten, Stoppen, Neustarten, Pausieren mit 1 Klick.
* 📜 **Live-Logs:** Klicke bei einem Container auf das Dokument-Symbol, um die Logs live zu streamen.
* 📈 **Stats:** Live-Graphen für CPU- und RAM-Verbrauch jedes Containers.
* 📦 **Images & Volumes:** Einfaches Löschen nicht mehr benötigter Images per Mausklick.

---

## 5. Terminal-Dashboard: Lazydocker (Optional)

Falls du ein extrem schnelles, tastaturgesteuertes Terminal-Dashboard bevorzugst:

```bash
# Installation via Curl (Binary nach ~/.local/bin)
curl https://raw.githubusercontent.com/jesseduffield/lazydocker/master/scripts/install_update.sh | bash
```

Starte es einfach mit:
```bash
lazydocker
```
*Mit Pfeiltasten zwischen Containern wechseln, Logs einsehen, Container mit `s` stoppen oder `r` neustarten.*

---

## 6. Tägliche CLI-Befehle für Container & Ressourcen

| Aufgabe | Befehl |
| :--- | :--- |
| **Alle aktiven Container anzeigen** | `docker ps` |
| **Alle Container (auch gestoppte) anzeigen** | `docker ps -a` |
| **Live-Ressourcenverbrauch (CPU, RAM, Net I/O)** | `docker stats` |
| **Live-Logs eines Containers ansehen** | `docker logs -f <container-name>` |
| **Container starten / stoppen** | `docker start <name>` / `docker stop <name>` |
| **Nicht genutzte Images & Cache bereinigen** | `docker system prune -a` |

---

## 7. Wo und wie werden Einstellungen verwaltet?

### A. Globale Docker-Daemon Einstellungen (`/etc/docker/daemon.json`)
Hier werden systemweite Einstellungen für die Docker Engine festgelegt.

Beispiel für eine optimierte Konfiguration (`sudo nano /etc/docker/daemon.json`):
```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "50m",
    "max-file": "3"
  },
  "default-address-pools": [
    {"base": "172.80.0.0/16", "size": 24}
  ]
}
```
*Verhindert z. B., dass Container-Logdateien unbemerkt die SSD vollschreiben.*  
Nach Änderungen: `sudo systemctl restart docker`.

### B. Container-Einstellungen (`docker-compose.yml`)
Jeder Dienst (z. B. `open-webui` oder `llm-speedup`) verwaltet seine eigenen Ports, Volumes und Umgebungs-Variablen in seiner eigenen `docker-compose.yml`.

### C. Systemd-Service-Einstellungen
* **Dienst neu starten:** `sudo systemctl restart docker`
* **Dienst beim Booten aktivieren / deaktivieren:** `sudo systemctl enable docker` bzw. `disable`
* **Daemon-Logs bei Problemen ansehen:** `journalctl -u docker -n 50 --no-pager`

---

## 8. Nächster Schritt nach der Bereinigung

Sobald Docker Desktop deinstalliert und `docker context use default` aktiv ist, kannst du direkt deinen beschleunigten LLM-Server starten:

```bash
cd /home/clemi/Projekte/LLM/llm-optimierungen/llm-speedup
./speedup-control.sh start
```
Die AMD Radeon Pro W7800 (`/dev/kfd` und `/dev/dri/renderD128`) wird nun sofort ohne VM-Hürde erkannt!

