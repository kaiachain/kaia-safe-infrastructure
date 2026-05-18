#!/usr/bin/env bash
# Upsert Kaia Kairos (chain id 1001) in Safe Config Service with Safe v1.5.0 *canonical*
# deployments (same as safe-global/safe-deployments PR 1462: Kaia Kairos maps to canonical).
#
# Prerequisites:
#   - safe-infrastructure-v2 stack running (`docker compose up -d`).
#   - cfg-web healthy; Django superuser exists if you rely on admin (this script uses manage.py shell).
#
# Env overrides:
#   TXS_URI            default http://nginx:8000/txs
#   RPC_URI            Kaia Kairos HTTPS RPC for cfg `rpc_uri` / `public_rpc_uri` / `safe_apps_rpc_uri`
#   EIP3770_SHORT_NAME default kairos (must be unique across chains)
#
# After running, verify:
#   curl -s "http://localhost:${REVERSE_PROXY_PORT:-8000}/cfg/api/v1/chains/1001/" | jq .
#
# Pair with Transaction Service registrations (includes SafeMigration trusted delegate-call):
#   ./scripts/seed_kairos_txs_contracts.sh
# Then restart CGW if you enabled FF_TRUSTED_DELEGATE_CALL (see container_env_files/cgw.env).

set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

TXS_URI="${TXS_URI:-http://nginx:8000/txs}"
RPC_URI="${RPC_URI:-https://public-en-kairos.node.kaia.io}"
EIP3770_SHORT_NAME="${EIP3770_SHORT_NAME:-kairos}"

export TXS_URI RPC_URI EIP3770_SHORT_NAME

docker compose exec -T cfg-web python src/manage.py shell <<'PY'
import os
import base64
from decimal import Decimal

from django.core.files.base import ContentFile

from chains.models import Chain, Feature, GasPrice

TXS_URI = os.environ["TXS_URI"]
RPC_URI = os.environ["RPC_URI"]
SHORT_NAME = os.environ["EIP3770_SHORT_NAME"]

# Canonical v1.5.0 addresses from @safe-global/safe-deployments (Kaia Kairos 1001 -> canonical).
SAFE_L2_SINGLETON = "0xEdd160fEBBD92E350D4D398fb636302fccd67C7e"
PROXY_FACTORY = "0x14F2982D601c9458F93bd70B218933A6f8165e7b"
MULTI_SEND = "0x218543288004CD07832472D464648173c77D7eB7"
MULTI_SEND_CALL_ONLY = "0xA83c336B20401Af773B6219BA5027174338D1836"
FALLBACK_HANDLER = "0x3EfCBb83A4A7AfcB4F68D501E2c2203a38be77f4"
SIGN_MESSAGE_LIB = "0x4FfeF8222648872B3dE295Ba1e49110E61f5b5aa"
CREATE_CALL = "0x2Ef5ECfbea521449E4De05EDB1ce63B75eDA90B4"
SIMULATE_TX_ACCESSOR = "0x07EfA797c55B5DdE3698d876b277aBb6B893654C"

PNG_B64 = (
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
)


def currency_png_content() -> ContentFile:
    return ContentFile(base64.b64decode(PNG_B64))

defaults = dict(
    relevance=500,
    name="Kaia Kairos",
    short_name=SHORT_NAME,
    description="Kaia Kairos testnet",
    l2=True,
    is_testnet=True,
    zk=False,
    rpc_authentication=Chain.RpcAuthentication.NO_AUTHENTICATION,
    rpc_uri=RPC_URI,
    safe_apps_rpc_authentication=Chain.RpcAuthentication.NO_AUTHENTICATION,
    safe_apps_rpc_uri=RPC_URI,
    public_rpc_authentication=Chain.RpcAuthentication.NO_AUTHENTICATION,
    public_rpc_uri=RPC_URI,
    block_explorer_uri_address_template="https://kairos.kaiascan.io/address/{{address}}",
    block_explorer_uri_tx_hash_template="https://kairos.kaiascan.io/tx/{{txHash}}",
    block_explorer_uri_api_template=(
        "https://kairos-oapi.kaiascan.io/api?module={{module}}&action={{action}}&address={{address}}"
        "&apikey={{apiKey}}"
    ),
    currency_name="KAIA",
    currency_symbol="KAIA",
    currency_decimals=18,
    transaction_service_uri=TXS_URI.rstrip("/"),
    vpc_transaction_service_uri=TXS_URI.rstrip("/"),
    vpc_rpc_uri=RPC_URI,
    theme_text_color="#ffffff",
    theme_background_color="#000000",
    ens_registry_address=None,
    recommended_master_copy_version="1.5.0",
    hidden=False,
    safe_singleton_address=SAFE_L2_SINGLETON,
    safe_proxy_factory_address=PROXY_FACTORY,
    multi_send_address=MULTI_SEND,
    multi_send_call_only_address=MULTI_SEND_CALL_ONLY,
    fallback_handler_address=FALLBACK_HANDLER,
    sign_message_lib_address=SIGN_MESSAGE_LIB,
    create_call_address=CREATE_CALL,
    simulate_tx_accessor_address=SIMULATE_TX_ACCESSOR,
)

chain, created = Chain.objects.update_or_create(id=1001, defaults=defaults)
chain.refresh_from_db()
if not chain.currency_logo_uri:
    chain.currency_logo_uri.save("kaia_currency.png", currency_png_content(), save=True)

GasPrice.objects.filter(chain=chain).delete()
GasPrice.objects.create(chain=chain, fixed_wei_value=25 * 10**9, rank=100, gwei_factor=Decimal(1))

# Ensure Safe Wallet Web feature flags are present on the chain and registered
# with the WALLET_WEB service.
#
# The v2 chains endpoint (/v2/chains/{serviceKey}) filters features by both:
#   1. chains M2M — the feature must be linked to this chain
#   2. services M2M — the feature must be linked to the target service
#
# Without the services link the v2 endpoint returns features: [] even when the
# feature is linked to the chain, causing the frontend to show a blank page.
from chains.models import Service  # noqa: E402 (already imported Chain, Feature above)

WALLET_FEATURES = [
    "CONTRACT_INTERACTION",
    "DOMAIN_LOOKUP",
    "ERC721",
    "ERC1155",
    "SAFE_APPS",
    "SPENDING_LIMIT",
    "EIP1559",
    "DEFAULT_TOKENS",
    "NATIVE_WALLETCONNECT",
    "COUNTERFACTUAL",
    "MULTI_CHAIN_SAFE_CREATION",
    "RECOVERY",
    "MY_ACCOUNTS",
    "WELCOME_ACCOUNTS_REDESIGN",
    "SEND_FLOW",
    "BATCHING",
]

wallet_svc, _ = Service.objects.get_or_create(
    key="WALLET_WEB",
    defaults={"name": "Safe Wallet Web", "description": "Browser wallet"},
)

existing_chain_keys = set(chain.feature_set.values_list("key", flat=True))
existing_svc_keys = set(Feature.objects.filter(services=wallet_svc).values_list("key", flat=True))

added_to_chain = []
added_to_svc = []
for key in WALLET_FEATURES:
    feature, _ = Feature.objects.get_or_create(key=key)
    if key not in existing_chain_keys:
        feature.chains.add(chain)
        added_to_chain.append(key)
    if key not in existing_svc_keys:
        feature.services.add(wallet_svc)
        added_to_svc.append(key)

verb = "created" if created else "updated"
print(f"seed_kairos_chain_cfg: chain 1001 {verb} ({chain.name}, short_name={chain.short_name})")
if added_to_chain:
    print(f"seed_kairos_chain_cfg: linked to chain: {added_to_chain}")
if added_to_svc:
    print(f"seed_kairos_chain_cfg: linked to WALLET_WEB service: {added_to_svc}")
if not added_to_chain and not added_to_svc:
    print("seed_kairos_chain_cfg: all wallet features already present")
PY
