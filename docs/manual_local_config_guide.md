# Manual Local Configuration Guide (Kaia Kairos)

This guide walks through **every step** that [`scripts/run_locally.sh`](../scripts/run_locally.sh) performs automatically, so you can configure the stack by hand. It targets **Kaia Kairos testnet (chain id 1001)**.

For the one-command bootstrap, use:

```bash
./scripts/run_locally.sh
```

---

## Overview

`run_locally.sh` does the following in order:

1. Pull images and start Docker Compose
2. Wait for Config Service (CFG) and Transaction Service (TXS) migrations
3. Create Django superusers (CFG + TXS)
4. Seed CFG **Service** rows (required for `/v2/chains`)
5. Seed Kaia Kairos **ChainInfo** in CFG
6. Seed TXS **MasterCopies**, **ProxyFactories**, and **trusted delegate-call contracts**
7. Print admin URLs and verification hints

---

## Prerequisites

- [Docker Compose](https://docs.docker.com/compose/install/) installed
- Git clone of this repository
- Ports available (default **8000** for the reverse proxy)
- Optional: [Brief Docker cheat sheet](docker_cheatsheet.md)

---

## Step 1 — Root `.env`

Copy the sample and set your RPC endpoint:

```bash
cp .env.sample .env
```

Edit `.env`:

| Variable | Purpose | Default / example |
|----------|---------|-------------------|
| `REVERSE_PROXY_PORT` | Host port for nginx | `8000` |
| `RPC_NODE_URL` | Kaia Kairos RPC used by TXS indexer and chain config | `https://public-en-kairos.node.kaia.io` |
| `CFG_VERSION` | Safe Config Service image tag | `v2.94.2` |
| `CGW_VERSION` | Client Gateway image tag | `v1.109.0` |
| `TXS_VERSION` | Transaction Service image tag | `v6.3.0` |
| `UI_VERSION` | Safe Wallet Web image tag | `v1.88.0` |
| `EVENTS_VERSION` | Events Service image tag | `v1.3.0` |

**Important:** Keep pinned versions aligned. Mixing `latest` tags can break the Web app (`/v2/chains`) vs Config API compatibility.

---

## Step 2 — Container environment files

Review these before first boot. Defaults in this repo are already set for local Kaia Kairos.

### `container_env_files/cfg.env`

Key settings:

- Superuser (non-interactive): `DJANGO_SUPERUSER_USERNAME=root`, `DJANGO_SUPERUSER_PASSWORD=admin`
- CGW webhook invalidation: `CGW_URL=http://nginx:8000/cgw`
- **Must match CGW:** `CGW_AUTH_TOKEN=your_privileged_endpoints_token`

### `container_env_files/cgw.env`

Key settings:

- Config Service URL: `SAFE_CONFIG_BASE_URI=http://nginx:8000/cfg`
- **Must match CFG:** `AUTH_TOKEN=your_privileged_endpoints_token` (same value as `CGW_AUTH_TOKEN`)
- Local delegate-call support: `FF_TRUSTED_DELEGATE_CALL=true`, `FF_TRUSTED_FOR_DELEGATE_CALL_CONTRACTS_LIST=true`
- Local contract decoder: `SAFE_DATA_DECODER_BASE_URI=http://decoder-shim:3001`

### `container_env_files/txs.env`

Key settings:

- L2 mode: `ETH_L2_NETWORK=1`
- Superuser: `DJANGO_SUPERUSER_USERNAME=root`, `DJANGO_SUPERUSER_PASSWORD=admin`
- RPC comes from root `.env` via `docker-compose.yml` (`ETHEREUM_NODE_URL=${RPC_NODE_URL}`)

### `container_env_files/ui.env`

Key settings:

- `NEXT_PUBLIC_GATEWAY_URL_PRODUCTION=http://localhost:8000/cgw`
- Set `NEXT_PUBLIC_INFURA_TOKEN` if your chain RPC requires Infura (Kaia public RPC usually does not)

### `container_env_files/events.env`

Default admin for Events panel: `admin@safe` / `password` (see Step 9 for webhooks).

---

## Step 3 — Start the stack

Equivalent to the script’s pull / down / up sequence.

**Fresh start (wipe all DB data):**

```bash
docker compose pull
docker compose down -v
docker compose up -d
```

**Restart keeping data (what the script does by default):**

```bash
docker compose pull
docker compose down
docker compose up -d
```

Data is stored under `./data/` (`txs-db`, `cfg-db`, `cgw-db`, `events-db`).

---

## Step 4 — Wait for migrations

Do **not** run `migrate` manually from the host. Migrations run inside containers:

| Service | Who runs migrations | Ready signal |
|---------|---------------------|--------------|
| Config Service | `cfg-web` entrypoint | Logs contain `Running Gunicorn` |
| Transaction Service | `txs-worker-indexer` (`RUN_MIGRATIONS=1`) | Logs contain `Setting up service` |

Check status:

```bash
docker compose ps
docker compose logs cfg-web --tail 50
docker compose logs txs-worker-indexer --tail 50
```

Wait until `cfg-web`, `txs-web`, and `txs-worker-indexer` are running and the log lines above appear.

**If migrations are stuck or schema looks wrong:** full reset:

```bash
RESET_VOLUMES=1 ./scripts/run_locally.sh
# or manually:
docker compose down -v && rm -rf ./data && docker compose up -d
```

---

## Step 5 — Create superusers

The script uses non-interactive createsuperuser (credentials from env files).

### Config Service

```bash
docker compose exec cfg-web python src/manage.py createsuperuser --noinput
```

Login: **http://localhost:8000/cfg/admin/** — user `root`, password `admin`

### Transaction Service

```bash
docker compose exec txs-web python manage.py createsuperuser --noinput
```

Login: **http://localhost:8000/txs/admin/** — user `root`, password `admin`

> Note: CFG uses `src/manage.py`; TXS uses `manage.py` at `/app`.

If the user already exists, the command may fail harmlessly — that is expected on re-runs.

---

## Step 6 — Seed CFG Service rows

Safe Web and CGW call **`GET /cfg/api/v2/chains/{serviceKey}`**. The Config Service requires **Service** records with matching keys.

**Automated (recommended):**

```bash
./scripts/seed_cfg_services.sh
```

**Manual (CFG admin):**

1. Open http://localhost:8000/cfg/admin/
2. Go to **Services** → **Add**
3. Create these rows:

| Key | Name | Description |
|-----|------|-------------|
| `WALLET_WEB` | Safe Wallet Web | Browser wallet (v2 `/v2/chains?serviceKey=…`) |
| `CGW` | Client Gateway | Safe Client Gateway |
| `frontend` | Frontend | Legacy / generic frontend key |

---

## Step 7 — Seed Kaia Kairos ChainInfo (CFG)

This registers chain **1001** with RPC URLs, block explorer templates, Safe v1.5.0 contract addresses, logos, and wallet feature flags.

**Automated (recommended):**

```bash
./scripts/seed_kairos_chain_cfg.sh
```

Optional overrides:

```bash
TXS_URI=http://nginx:8000/txs \
RPC_URI=https://public-en-kairos.node.kaia.io \
EIP3770_SHORT_NAME=Kairos \
./scripts/seed_kairos_chain_cfg.sh
```

**Manual (CFG admin):**

1. Open http://localhost:8000/cfg/admin/chains/chain/add/
2. Set **Chain id** to `1001`
3. Fill fields per [chain_info.md](chain_info.md). Critical values:

| Field | Value |
|-------|-------|
| Name | `Kairos` |
| Short name (EIP-3770) | `Kairos` (must be unique) |
| L2 | Yes |
| Is testnet | Yes |
| RPC URI / Public RPC / Safe Apps RPC | Your Kaia Kairos RPC |
| Transaction service URI | `http://nginx:8000/txs` |
| VPC transaction service URI | `http://nginx:8000/txs` |
| Recommended master copy version | `1.5.0` |
| Safe singleton (L2) | `0xEdd160fEBBD92E350D4D398fb636302fccd67C7e` |
| Safe proxy factory | `0x14F2982D601c9458F93bd70B218933A6f8165e7b` |
| MultiSend | `0x218543288004CD07832472D464648173c77D7eB7` |
| MultiSendCallOnly | `0xA83c336B20401Af773B6219BA5027174338D1836` |
| Fallback handler | `0x85a8ca358d388530ad0fb95d0cb89dd44fc242c3` |
| Sign message lib | `0x4FfeF8222648872B3dE295Ba1e49110E61f5b5aa` |
| Create call | `0x2Ef5ECfbea521449E4De05EDB1ce63B75eDA90B4` |
| Simulate tx accessor | `0x07EfA797c55B5DdE3698d876b277aBb6B893654C` |
| Block explorer address template | `https://kairos.kaiascan.io/address/{{address}}` |
| Block explorer tx template | `https://kairos.kaiascan.io/tx/{{txHash}}` |

4. Upload chain/currency logos (or use bundled asset at `scripts/assets/kaia_chain_logo.png`)
5. Link **Features** to chain **and** to the `WALLET_WEB` service (both M2M relations required for v2 API):

   `CONTRACT_INTERACTION`, `DOMAIN_LOOKUP`, `ERC721`, `ERC1155`, `SAFE_APPS`, `SPENDING_LIMIT`, `EIP1559`, `DEFAULT_TOKENS`, `NATIVE_WALLETCONNECT`, `COUNTERFACTUAL`, `MULTI_CHAIN_SAFE_CREATION`, `RECOVERY`, `MY_ACCOUNTS`, `WELCOME_ACCOUNTS_REDESIGN`, `SEND_FLOW`, `BATCHING`

6. Remove any fixed **Gas price** rows for this chain (Kaia uses EIP-1559)

**Verify:**

```bash
curl -s http://localhost:8000/cfg/api/v1/chains/1001/ | jq .name
```

---

## Step 8 — Seed TXS contracts (MasterCopies, ProxyFactories, trusted delegate)

Kaia Kairos is not in the default TXS auto-setup list. Register deployments and migration contracts so indexing and delegate-call proposals work.

**Automated (recommended):**

```bash
./scripts/seed_kairos_txs_contracts.sh
```

This upserts:

| Contract | Version | Address |
|----------|---------|---------|
| SafeL2 (legacy) | 1.3.0+L2 | `0xfb1bffc9d739b8d520daf37df666da4c687191ea` |
| ProxyFactory (legacy) | 1.3.0 | `0xc22834581ebc8527d974f8a1c97e1bea4ef910bc` |
| SafeL2 (canonical) | 1.5.0 | `0xEdd160fEBBD92E350D4D398fb636302fccd67C7e` |
| ProxyFactory (canonical) | 1.5.0 | `0x14F2982D601c9458F93bd70B218933A6f8165e7b` |
| SafeMigration (trusted delegate) | 1.4.1 / 1.5.0 | `0x526643f69b81b008f46d95cd5ced5ec0edffdac6`, `0x6439e7abd8bb915a5263094784c5cf561c4172ac` |

It also resets index cursors and queues reindex tasks.

**Manual (TXS admin):**

1. Open http://localhost:8000/txs/admin/
2. **History → Safe master copies** — add each SafeL2 row with correct `initial_block_number`, `version`, `l2=true`
3. **History → Proxy factories** — add each ProxyFactory row
4. **Contracts → Contracts** — add SafeMigration contracts with **Trusted for delegate call** enabled

Default deployment blocks (Kairos mainnet history):

| Contract | Initial block |
|----------|---------------|
| ProxyFactory v1.3.0 | `93821613` |
| SafeL2 v1.3.0+L2 | `93821635` |
| ProxyFactory v1.5.0 | `193992287` |
| SafeL2 v1.5.0 | `208460463` |

Refresh blocks with:

```bash
KAIASCAN_API_KEY=... python scripts/fetch_kairos_contract_deploy_blocks.py
```

**Verify:**

```bash
curl -s "http://localhost:8000/txs/api/v1/contracts/?trusted_for_delegate_call=true&limit=20" | jq .
```

After changing `FF_TRUSTED_DELEGATE_CALL` in `cgw.env`, restart CGW:

```bash
docker compose restart cgw-web
```

---

## Step 9 — Events webhooks (optional but recommended)

Cache invalidation between TXS/CFG and CGW uses the Events service.

1. Open http://localhost:8000/events/admin/
2. Login: `admin@safe` / `password` (from `container_env_files/events.env`)
3. **Webhooks** → **Create new**
4. Set:
   - **Url:** `http://nginx:8000/cgw/v1/hooks/events`
   - **Description:** `CGW`
   - **Is Active:** enabled
   - **Authorization:** `Basic your_privileged_endpoints_token` (same as `AUTH_TOKEN` in `cgw.env`)
   - **Chains:** leave blank
   - Enable all webhook event types → **Save**

If you changed `CGW_AUTH_TOKEN` / `AUTH_TOKEN`, update both CFG/CGW env files **before** starting containers (Step 2).

---

## Step 10 — Verify the full stack

Run the same checks as the script comments:

```bash
# Config Service — chain metadata
curl -s http://localhost:8000/cfg/api/v1/chains/1001/ | jq .name

# Client Gateway — exposes chain to frontend
curl -s http://localhost:8000/cgw/v1/chains | jq '.[0].chainId'
```

**URLs:**

| Service | URL | Credentials |
|---------|-----|-------------|
| Safe Wallet Web | http://localhost:8000/ | — |
| CFG admin | http://localhost:8000/cfg/admin/ | `root` / `admin` |
| TXS admin | http://localhost:8000/txs/admin/ | `root` / `admin` |
| Events admin | http://localhost:8000/events/admin/ | `admin@safe` / `password` |

The UI container runs a Next.js build on first start and may take **15+ minutes**.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Blank Safe Web page | Features not linked to `WALLET_WEB` service | Re-run Step 6–7 or `./scripts/seed_kairos_chain_cfg.sh` |
| `/v2/chains` empty or 404 | Missing Service rows | Step 6 |
| TXS not indexing | Wrong `RPC_NODE_URL` or missing MasterCopies | Step 1 + Step 8 |
| Migration errors / corrupt schema | Concurrent migrate or stale volume | `RESET_VOLUMES=1 ./scripts/run_locally.sh` |
| Delegate-call proposals rejected | CGW flags or missing trusted contracts | Check `cgw.env` flags + Step 8 |
| Logo 404 on chain config | Media not synced to nginx volume | Re-run `./scripts/seed_kairos_chain_cfg.sh` |

---

## Quick reference — script vs manual

| `run_locally.sh` action | Manual equivalent |
|-------------------------|-------------------|
| `docker compose pull && down && up -d` | Step 3 |
| Wait for Gunicorn / Setting up service | Step 4 |
| `createsuperuser --noinput` (cfg + txs) | Step 5 |
| `seed_cfg_services.sh` | Step 6 |
| `seed_kairos_chain_cfg.sh` | Step 7 |
| `seed_kairos_txs_contracts.sh` | Step 8 |
| Events webhook | Step 9 |
| Health curls | Step 10 |
