#!/bin/bash

# Detect which compose file to use (macOS/Windows Docker Desktop doesn't support network_mode: host)
if [[ "$(uname)" == "Linux" ]]; then
  COMPOSE_FILE="docker-compose.yml"
else
  COMPOSE_FILE="docker-compose.macos.yml"
fi

docker compose -f "$COMPOSE_FILE" down
git pull origin main
docker compose -f "$COMPOSE_FILE" up -d --build
docker logs ollama-server-manager
