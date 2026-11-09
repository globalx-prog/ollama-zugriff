#!/bin/bash
# Startet alle Container des ollama-zugriff Stacks
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Starte Open WebUI, SearXNG und Cloudflared Tunnel..."
cd "$DIR/open-webui" && docker compose up -d
cd "$DIR/searxng" && docker compose up -d
cd "$DIR/tunnel" && docker compose up -d
echo "✓ Alle Dienste erfolgreich gestartet."
