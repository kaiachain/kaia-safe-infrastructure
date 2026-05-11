#!/usr/bin/env bash
# Register Safe v1.5.0 canonical **SafeL2** master copy + **SafeProxyFactory** on the local
# Transaction Service (same addresses as safe-global/safe-deployments canonical / PR 1462 for Kaia Kairos).
#
# Also registers **SafeMigration** library contracts with trusted_for_delegate_call=true so the
# Client Gateway accepts delegate-call proposals (migrateL2Singleton / upgrade flows). Matches
# @safe-global/safe-deployments for chain 1001 (canonical addresses).
#
# Uses **PostgreSQL** (`txs-db`) instead of `manage.py shell` so it keeps working when the TXS image
# hits Django model-loader issues (e.g. INSTALLED_APPS / app_label errors under Python 3.13).
#
# The TX service watches `ETHEREUM_NODE_URL` from `container_env_files/txs.env` (.env RPC_NODE_URL):
# point it at Kaia Kairos (1001) when indexing this chain.
#
# Prerequisites:
#   - `docker compose up -d` (txs-db, txs-web, … healthy).
#
# Default initial blocks match KaiaScan contract-creation (Kairos 1001); refresh with:
#   KAIASCAN_API_KEY=... ./scripts/fetch_kairos_contract_deploy_blocks.py
#
# Env overrides:
#   INITIAL_BLOCK_NUMBER       Fallback when a per-contract var is empty (default 0).
#   SAFE_L2_INITIAL_BLOCK      SafeL2 singleton first block (default 208460463).
#   PROXY_FACTORY_INITIAL_BLOCK  Proxy factory first block (default 193992287).
#   SAFE_V150_INITIAL_BLOCK    Non-L2 Safe singleton when ADD_SAFE_V15_PRIMARY (default 193992292).
#   ADD_SAFE_V15_PRIMARY       If set to 1, also register non-L2 Safe singleton v1.5.0 (canonical).
#
# Full-chain rescan: set all three *_INITIAL_BLOCK to 0 (or only INITIAL_BLOCK_NUMBER=0 and clear the others).
#
# Fetch deployment blocks from Kaiascan (needs KAIASCAN_API_KEY):
#   ./scripts/fetch_kairos_contract_deploy_blocks.py --shell
#
# Related: ./seed_kairos_chain_cfg.sh (Config Service ChainInfo).
#
# Verify (TXS is source of truth for trusted delegate-call registration):
#   curl -s "http://localhost:${REVERSE_PROXY_PORT:-8000}/txs/api/v1/contracts/?chain_ids=1001&trusted_for_delegate_call=true&limit=20" | jq .
# Optional: single row — curl -s "http://localhost:${REVERSE_PROXY_PORT:-8000}/txs/api/v1/contracts/0x526643F69b81B008F46d95CD5ced5eC0edFFDaC6/" | jq .
# CGW GET /cgw/v1/chains/1001/contracts/... can 502 if SAFE_DATA_DECODER_BASE_URI is local TXS (response shape); migration uses the paginated TXS list API instead.
#
# CGW must have FF_TRUSTED_DELEGATE_CALL=true (see container_env_files/cgw.env).

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

INITIAL_BLOCK_NUMBER="${INITIAL_BLOCK_NUMBER:-0}"
SAFE_L2_INITIAL_BLOCK="${SAFE_L2_INITIAL_BLOCK:-208460463}"
PROXY_FACTORY_INITIAL_BLOCK="${PROXY_FACTORY_INITIAL_BLOCK:-193992287}"
SAFE_V150_INITIAL_BLOCK="${SAFE_V150_INITIAL_BLOCK:-193992292}"
ADD_SAFE_V15_PRIMARY="${ADD_SAFE_V15_PRIMARY:-}"

_ibl() {
  local name="$1"
  local raw="${!name:-}"
  raw="${raw:-}"
  if [[ -n "${raw}" ]]; then
    echo "${raw}"
  else
    echo "${INITIAL_BLOCK_NUMBER}"
  fi
}

BLOCK_SAFE_L2="$(_ibl SAFE_L2_INITIAL_BLOCK)"
BLOCK_PF="$(_ibl PROXY_FACTORY_INITIAL_BLOCK)"
BLOCK_SAFE_V150="$(_ibl SAFE_V150_INITIAL_BLOCK)"

# Lowercase hex without 0x for decode(..., 'hex')
SAFE_L2_V150="edd160febbd92e350d4d398fb636302fccd67c7e"
SAFE_V150="ff51a5898e281db6dfc7855790607438df2ca44b"
PROXY_FACTORY_V150="14f2982d601c9458f93bd70b218933a6f8165e7b"

SAFE_MIGRATION_V141="526643f69b81b008f46d95cd5ced5ec0edffdac6"
SAFE_MIGRATION_V150="6439e7abd8bb915a5263094784c5cf561c4172ac"

docker compose exec -T txs-db psql -U postgres -d postgres -v ON_ERROR_STOP=1 <<SQL
INSERT INTO history_safemastercopy (address, initial_block_number, tx_block_number, version, deployer, l2)
VALUES (decode('${SAFE_L2_V150}', 'hex'), ${BLOCK_SAFE_L2}, NULL, '1.5.0', 'Safe', true)
ON CONFLICT (address) DO UPDATE SET
  initial_block_number = EXCLUDED.initial_block_number,
  version = EXCLUDED.version,
  deployer = EXCLUDED.deployer,
  l2 = EXCLUDED.l2;

INSERT INTO history_proxyfactory (address, initial_block_number, tx_block_number)
VALUES (decode('${PROXY_FACTORY_V150}', 'hex'), ${BLOCK_PF}, NULL)
ON CONFLICT (address) DO UPDATE SET
  initial_block_number = EXCLUDED.initial_block_number;

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
VALUES (decode('${SAFE_V150}', 'hex'), ${BLOCK_SAFE_V150}, NULL, '1.5.0', 'Safe', false)
ON CONFLICT (address) DO UPDATE SET
  initial_block_number = EXCLUDED.initial_block_number,
  version = EXCLUDED.version,
  deployer = EXCLUDED.deployer,
  l2 = EXCLUDED.l2;
SQL
fi

echo "seed_kairos_txs_contracts: SafeMasterCopy(L2,v1.5.0) upserted 0x${SAFE_L2_V150} | ProxyFactory upserted 0x${PROXY_FACTORY_V150}"
echo "seed_kairos_txs_contracts: Contract(trusted delegate) upserted SafeMigration v1.4.1 / v1.5.0"
if [[ "${ADD_SAFE_V15_PRIMARY}" =~ ^(1|true|yes)$ ]]; then
  echo "seed_kairos_txs_contracts: SafeMasterCopy(1-of-1,v1.5.0) upserted 0x${SAFE_V150}"
fi
