#!/usr/bin/env bash
# Register Safe master copies + proxy factories on the local Transaction Service for Kaia Kairos
# (chain id 1001). Covers all contract versions currently tracked by the live TXS database:
#
#   v1.3.0+L2  SafeL2 + ProxyFactory  (legacy Safes deployed early on Kairos)
#   v1.5.0     SafeL2 + ProxyFactory  (canonical, safe-global/safe-deployments PR 1462)
#
# Also registers SafeMigration library contracts with trusted_for_delegate_call=true so the
# Client Gateway accepts delegate-call proposals (migrateL2Singleton / upgrade flows).
#
# Uses PostgreSQL (txs-db) directly — avoids Django model-loader issues with TXS images.
#
# The TX service watches ETHEREUM_NODE_URL from container_env_files/txs.env (.env RPC_NODE_URL):
# point it at Kaia Kairos (1001) when indexing this chain.
#
# Prerequisites:
#   - `docker compose up -d` (txs-db, txs-web, … healthy).
#
# Default initial blocks match KaiaScan contract-creation tx receipts (Kairos 1001); refresh with:
#   KAIASCAN_API_KEY=... ./scripts/fetch_kairos_contract_deploy_blocks.py
#
# tx_block_number is set to the same deployment block as initial_block_number (TXS admin "Tx block number").
# Env overrides:
#   INITIAL_BLOCK_NUMBER            Fallback when a per-contract var is unset (default 0).
#   SAFE_L2_V130_INITIAL_BLOCK      SafeL2 v1.3.0+L2 first block (default 93821635).
#   PROXY_FACTORY_V130_INITIAL_BLOCK  ProxyFactory v1.3.0 first block (default 93821613).
#   SAFE_L2_INITIAL_BLOCK           SafeL2 v1.5.0 first block (default 208460463).
#   PROXY_FACTORY_INITIAL_BLOCK     ProxyFactory v1.5.0 first block (default 193992287).
#   SAFE_V150_INITIAL_BLOCK         Non-L2 Safe v1.5.0 when ADD_SAFE_V15_PRIMARY (default 193992292).
#   ADD_SAFE_V15_PRIMARY            Set to 1 to also register non-L2 Safe singleton v1.5.0.
#
# Full-chain rescan: set all *_INITIAL_BLOCK vars to 0 (or set only INITIAL_BLOCK_NUMBER=0).
#
# After upserting blocks, cursors are reset (tx_block_number = initial_block_number) and L2 indexer
# tasks are queued so the worker rescans from the earliest deployment block. Disable with:
#   RESET_TX_INDEX_CURSORS=0  or  TRIGGER_TXS_REINDEX=0
#
# Related: ./seed_kairos_chain_cfg.sh (Config Service ChainInfo).
#
# Verify:
#   curl -s "http://localhost:${REVERSE_PROXY_PORT:-8000}/txs/api/v1/contracts/?trusted_for_delegate_call=true&limit=20" | jq .
#   docker compose exec txs-db psql -U postgres -d postgres -c "SELECT encode(address,'hex'), version, l2 FROM history_safemastercopy;"
#
# CGW must have FF_TRUSTED_DELEGATE_CALL=true (see container_env_files/cgw.env).

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

INITIAL_BLOCK_NUMBER="${INITIAL_BLOCK_NUMBER:-0}"
# v1.3.0 legacy contracts (early Kairos deployments)
SAFE_L2_V130_INITIAL_BLOCK="${SAFE_L2_V130_INITIAL_BLOCK:-93821635}"
PROXY_FACTORY_V130_INITIAL_BLOCK="${PROXY_FACTORY_V130_INITIAL_BLOCK:-93821613}"
# v1.5.0 canonical contracts
SAFE_L2_INITIAL_BLOCK="${SAFE_L2_INITIAL_BLOCK:-208460463}"
PROXY_FACTORY_INITIAL_BLOCK="${PROXY_FACTORY_INITIAL_BLOCK:-193992287}"
SAFE_V150_INITIAL_BLOCK="${SAFE_V150_INITIAL_BLOCK:-193992292}"
ADD_SAFE_V15_PRIMARY="${ADD_SAFE_V15_PRIMARY:-}"

_ibl() {
  local name="$1"
  local raw="${!name:-}"
  if [[ -n "${raw}" ]]; then
    echo "${raw}"
  else
    echo "${INITIAL_BLOCK_NUMBER}"
  fi
}

BLOCK_SAFE_L2_V130="$(_ibl SAFE_L2_V130_INITIAL_BLOCK)"
BLOCK_PF_V130="$(_ibl PROXY_FACTORY_V130_INITIAL_BLOCK)"
BLOCK_SAFE_L2="$(_ibl SAFE_L2_INITIAL_BLOCK)"
BLOCK_PF="$(_ibl PROXY_FACTORY_INITIAL_BLOCK)"
BLOCK_SAFE_V150="$(_ibl SAFE_V150_INITIAL_BLOCK)"

# Lowercase hex without 0x for decode(..., 'hex')
# v1.3.0 legacy (deployed early on Kairos)
SAFE_L2_V130="fb1bffc9d739b8d520daf37df666da4c687191ea"
PROXY_FACTORY_V130="c22834581ebc8527d974f8a1c97e1bea4ef910bc"
# v1.5.0 canonical
SAFE_L2_V150="edd160febbd92e350d4d398fb636302fccd67c7e"
SAFE_V150="ff51a5898e281db6dfc7855790607438df2ca44b"
PROXY_FACTORY_V150="14f2982d601c9458f93bd70b218933a6f8165e7b"

SAFE_MIGRATION_V141="526643f69b81b008f46d95cd5ced5ec0edffdac6"
SAFE_MIGRATION_V150="6439e7abd8bb915a5263094784c5cf561c4172ac"

docker compose exec -T txs-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
-- v1.3.0+L2 SafeL2 singleton (legacy Kairos deployments)
INSERT INTO history_safemastercopy (address, initial_block_number, tx_block_number, version, deployer, l2)
VALUES (decode('${SAFE_L2_V130}', 'hex'), ${BLOCK_SAFE_L2_V130}, ${BLOCK_SAFE_L2_V130}, '1.3.0+L2', 'Safe', true)
ON CONFLICT (address) DO UPDATE SET
  initial_block_number = EXCLUDED.initial_block_number,
  tx_block_number = EXCLUDED.tx_block_number,
  version = EXCLUDED.version,
  deployer = EXCLUDED.deployer,
  l2 = EXCLUDED.l2;

-- v1.3.0 ProxyFactory (legacy Kairos deployments)
INSERT INTO history_proxyfactory (address, initial_block_number, tx_block_number)
VALUES (decode('${PROXY_FACTORY_V130}', 'hex'), ${BLOCK_PF_V130}, ${BLOCK_PF_V130})
ON CONFLICT (address) DO UPDATE SET
  initial_block_number = EXCLUDED.initial_block_number,
  tx_block_number = EXCLUDED.tx_block_number;

-- v1.5.0 SafeL2 singleton (canonical)
INSERT INTO history_safemastercopy (address, initial_block_number, tx_block_number, version, deployer, l2)
VALUES (decode('${SAFE_L2_V150}', 'hex'), ${BLOCK_SAFE_L2}, ${BLOCK_SAFE_L2}, '1.5.0', 'Safe', true)
ON CONFLICT (address) DO UPDATE SET
  initial_block_number = EXCLUDED.initial_block_number,
  tx_block_number = EXCLUDED.tx_block_number,
  version = EXCLUDED.version,
  deployer = EXCLUDED.deployer,
  l2 = EXCLUDED.l2;

-- v1.5.0 ProxyFactory (canonical)
INSERT INTO history_proxyfactory (address, initial_block_number, tx_block_number)
VALUES (decode('${PROXY_FACTORY_V150}', 'hex'), ${BLOCK_PF}, ${BLOCK_PF})
ON CONFLICT (address) DO UPDATE SET
  initial_block_number = EXCLUDED.initial_block_number,
  tx_block_number = EXCLUDED.tx_block_number;

-- SafeMigration contracts — trusted_for_delegate_call=true required by CGW FF_TRUSTED_DELEGATE_CALL
INSERT INTO contracts_contract (address, name, contract_abi_id, display_name, logo, trusted_for_delegate_call)
VALUES
  (decode('${SAFE_MIGRATION_V141}', 'hex'), 'SafeMigration', NULL, 'SafeMigration v1.4.1', '', true),
  (decode('${SAFE_MIGRATION_V150}', 'hex'), 'SafeMigration', NULL, 'SafeMigration v1.5.0', '', true)
ON CONFLICT (address) DO UPDATE SET
  name = EXCLUDED.name,
  display_name = EXCLUDED.display_name,
  logo = EXCLUDED.logo,
  trusted_for_delegate_call = EXCLUDED.trusted_for_delegate_call;
SQL

if [[ "${ADD_SAFE_V15_PRIMARY}" =~ ^(1|true|yes)$ ]]; then
  docker compose exec -T txs-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
INSERT INTO history_safemastercopy (address, initial_block_number, tx_block_number, version, deployer, l2)
VALUES (decode('${SAFE_V150}', 'hex'), ${BLOCK_SAFE_V150}, ${BLOCK_SAFE_V150}, '1.5.0', 'Safe', false)
ON CONFLICT (address) DO UPDATE SET
  initial_block_number = EXCLUDED.initial_block_number,
  tx_block_number = EXCLUDED.tx_block_number,
  version = EXCLUDED.version,
  deployer = EXCLUDED.deployer,
  l2 = EXCLUDED.l2;
SQL
fi

echo "seed_kairos_txs_contracts: SafeMasterCopy(L2,v1.3.0+L2) upserted 0x${SAFE_L2_V130}"
echo "seed_kairos_txs_contracts: ProxyFactory(v1.3.0) upserted 0x${PROXY_FACTORY_V130}"
echo "seed_kairos_txs_contracts: SafeMasterCopy(L2,v1.5.0) upserted 0x${SAFE_L2_V150} | ProxyFactory(v1.5.0) upserted 0x${PROXY_FACTORY_V150}"
echo "seed_kairos_txs_contracts: Contract(trusted delegate) upserted SafeMigration v1.4.1 / v1.5.0"
if [[ "${ADD_SAFE_V15_PRIMARY}" =~ ^(1|true|yes)$ ]]; then
  echo "seed_kairos_txs_contracts: SafeMasterCopy(non-L2,v1.5.0) upserted 0x${SAFE_V150}"
fi

RESET_TX_INDEX_CURSORS="${RESET_TX_INDEX_CURSORS:-1}"
TRIGGER_TXS_REINDEX="${TRIGGER_TXS_REINDEX:-1}"

if [[ "${RESET_TX_INDEX_CURSORS}" =~ ^(1|true|yes)$ ]]; then
  echo "seed_kairos_txs_contracts: resetting index cursors (tx_block_number = initial_block_number)..."
  docker compose exec -T txs-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<'SQL'
-- Same as TXS admin action "Reindex from initial block" on SafeMasterCopy / ProxyFactory.
UPDATE history_safemastercopy SET tx_block_number = initial_block_number;
UPDATE history_proxyfactory SET tx_block_number = initial_block_number;

-- ERC20/721 pipeline (indexing_type 0): rewind to earliest L2 master copy deployment block.
INSERT INTO history_indexingstatus (indexing_type, block_number)
SELECT 0, COALESCE(MIN(initial_block_number), 0)
FROM history_safemastercopy
WHERE l2 = true
ON CONFLICT (indexing_type) DO UPDATE
SET block_number = EXCLUDED.block_number;
SQL

  MIN_BLOCK="$(
    docker compose exec -T txs-db psql -U postgres -d postgres -tAc \
      "SELECT COALESCE(MIN(initial_block_number), 0) FROM history_safemastercopy WHERE l2 = true;"
  )"
  echo "seed_kairos_txs_contracts: index cursors reset; earliest L2 master copy block=${MIN_BLOCK}"
fi

if [[ "${TRIGGER_TXS_REINDEX}" =~ ^(1|true|yes)$ ]]; then
  echo "seed_kairos_txs_contracts: queueing TXS indexer tasks (safe events + ERC20/721)..."
  if docker compose exec -T txs-web python manage.py shell -c "
from safe_transaction_service.history.tasks import index_erc20_events_task, index_safe_events_task

index_safe_events_task.delay()
index_erc20_events_task.delay()
print('queued index_safe_events_task and index_erc20_events_task')
"; then
    echo "seed_kairos_txs_contracts: indexer tasks queued (txs-worker-indexer will resync from reset cursors)"
  else
    echo "seed_kairos_txs_contracts: warning: could not queue indexer tasks — is txs-worker-indexer running?" >&2
  fi
fi
