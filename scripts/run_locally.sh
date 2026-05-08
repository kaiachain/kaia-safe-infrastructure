#!/bin/bash

set -e

RESET_VOLUMES="${RESET_VOLUMES:-0}"

echo "==> $(date +%H:%M:%S) ==> Pulling images..."
docker compose pull

if [ "$RESET_VOLUMES" = "1" ]; then
  echo "==> $(date +%H:%M:%S) ==> Resetting containers + volumes..."
  docker compose down -v
else
  echo "==> $(date +%H:%M:%S) ==> Stopping containers (keeping volumes)..."
  docker compose down
fi

echo "==> $(date +%H:%M:%S) ==> Starting containers..."
docker compose up -d

echo "==> $(date +%H:%M:%S) ==> Creating super-user for Safe Config Service (non-interactive)..."
docker compose exec -T cfg-web python src/manage.py createsuperuser --noinput || true

echo "==> $(date +%H:%M:%S) ==> Seeding Config Service rows for GET /cgw/v2/chains (WALLET_WEB, …)..."
bash "$(dirname "$0")/seed_cfg_services.sh" || true

echo "==> $(date +%H:%M:%S) ==> Creating super-user for Safe Transaction Service (non-interactive)..."
docker compose exec -T txs-web python manage.py createsuperuser --noinput || true

echo "==> $(date +%H:%M:%S) ==> All set! You may want to add a ChainInfo into the Config service. Please use the link below to fill its data: http://localhost:8000/cfg/admin/chains/chain/add/"
