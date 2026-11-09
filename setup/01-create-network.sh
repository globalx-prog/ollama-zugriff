#!/bin/bash
# Erstellt das gemeinsame ai-network falls noch nicht vorhanden
set -euo pipefail

if ! docker network inspect ai-network >/dev/null 2>&1; then
    echo "Erstelle Docker-Netzwerk 'ai-network'..."
    docker network create ai-network
    echo "✓ 'ai-network' erfolgreich erstellt."
else
    echo "✔ 'ai-network' existiert bereits."
fi
