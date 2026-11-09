#!/bin/bash
# Status aller Ollama-Zugriff Docker-Container prüfen
echo "=== Docker Container Status (ollama-zugriff) ==="
docker ps --filter "name=open-webui" --filter "name=searxng" --filter "name=cloudflared"

echo ""
echo "=== Port-Bindings auf 127.0.0.1 ==="
ss -tulpn | grep -E ':3000|:8081' || true
