#!/bin/bash
# Sicheres Neustarten des gesamten ollama-zugriff Stacks
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Starte ollama-zugriff Stack neu..."
cd "$DIR/open-webui" && docker compose restart
cd "$DIR/searxng" && docker compose restart
cd "$DIR/tunnel" && docker compose restart
echo "✓ Stack erfolgreich neu gestartet."
