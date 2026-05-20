#!/bin/bash
# Bootstrap the full local Safe stack for Kaia Kairos (chain id 1001).
#
# Usage:
#   ./scripts/run_locally.sh               # restart containers, re-seed (safe to re-run)
#   RESET_VOLUMES=1 ./scripts/run_locally.sh  # wipe data volumes first (full reset)
#
# After running, verify the stack is healthy:
#   curl -s http://localhost:8000/cfg/api/v1/chains/1001/ | jq .name
#   curl -s http://localhost:8000/cgw/v1/chains | jq '.[0].chainId'

set -e

RESET_VOLUMES="${RESET_VOLUMES:-0}"
SCRIPTS_DIR="$(cd "$(dirname "$0")" && pwd)"

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

echo "==> $(date +%H:%M:%S) ==> Seeding Config Service rows for GET /cgw/v2/chains (WALLET_WEB, CGW, frontend)..."
bash "${SCRIPTS_DIR}/seed_cfg_services.sh" || true

echo "==> $(date +%H:%M:%S) ==> Seeding Kaia Kairos chain config in Config Service..."
bash "${SCRIPTS_DIR}/seed_kairos_chain_cfg.sh" || true

echo "==> $(date +%H:%M:%S) ==> Creating super-user for Safe Transaction Service (non-interactive)..."
docker compose exec -T txs-web python manage.py createsuperuser --noinput || true

echo "==> $(date +%H:%M:%S) ==> Seeding Kaia Kairos master copies + trusted contracts in Transaction Service..."
bash "${SCRIPTS_DIR}/seed_kairos_txs_contracts.sh" || true

echo "==> $(date +%H:%M:%S) ==> Done! Stack is running at http://localhost:${REVERSE_PROXY_PORT:-8000}"
echo "==> CFG admin:  http://localhost:${REVERSE_PROXY_PORT:-8000}/cfg/admin/  (user: root / pass: admin)"
echo "==> TXS admin:  http://localhost:${REVERSE_PROXY_PORT:-8000}/txs/admin/  (user: root / pass: admin)"
