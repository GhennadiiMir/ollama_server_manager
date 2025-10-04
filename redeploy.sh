#!/bin/bash

docker compose down
git pull origin main
docker compose up -d --build
docker logs ollama-server-manager