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

wait_for_service() {
  local service="$1"
  local max_attempts="${2:-60}"
  local attempt=0
  while [ "$attempt" -lt "$max_attempts" ]; do
    if docker compose ps --status running --services 2>/dev/null | grep -qx "$service"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  echo "Timed out waiting for ${service} to start" >&2
  return 1
}

wait_for_log_line() {
  local service="$1"
  local pattern="$2"
  local label="$3"
  local max_attempts="${4:-90}"
  local attempt=0
  echo "==> $(date +%H:%M:%S) ==> Waiting for ${label}..."
  while [ "$attempt" -lt "$max_attempts" ]; do
    if docker compose logs "$service" 2>/dev/null | grep -q "$pattern"; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 2
  done
  echo "Timed out waiting for ${label}" >&2
  echo "Hint: if migrations are stuck or the DB schema is inconsistent, run:" >&2
  echo "      RESET_VOLUMES=1 ./scripts/run_locally.sh" >&2
  return 1
}

echo "==> $(date +%H:%M:%S) ==> Waiting for cfg-web, txs-web, and txs-worker-indexer..."
wait_for_service cfg-web
wait_for_service txs-web
wait_for_service txs-worker-indexer

# cfg-web entrypoint runs migrate; txs-worker-indexer runs migrate when RUN_MIGRATIONS=1.
# Do not run migrate from this script — concurrent migrate processes corrupt schema state.
wait_for_log_line cfg-web "Running Gunicorn" "Config Service migrations (cfg-web entrypoint)"
wait_for_log_line txs-worker-indexer "Setting up service" "Transaction Service migrations (txs-worker-indexer)"

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

echo "==> $(date +%H:%M:%S) ==> Done! Backend APIs at http://localhost:${REVERSE_PROXY_PORT:-8000} (/cgw, /cfg, /txs, /events)"
echo "==> Wallet UI: run kaia-safe-wallet-web locally (not bundled in this compose stack)"
echo "==> CFG admin:  http://localhost:${REVERSE_PROXY_PORT:-8000}/cfg/admin/  (user: root / pass: admin)"
echo "==> TXS admin:  http://localhost:${REVERSE_PROXY_PORT:-8000}/txs/admin/  (user: root / pass: admin)"
