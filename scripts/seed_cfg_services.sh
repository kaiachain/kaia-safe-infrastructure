#!/usr/bin/env bash
# Config Service v2 chain APIs require Service rows (chains.views ChainsListViewV2).
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

docker compose exec -T cfg-web python src/manage.py shell <<'PY'
from chains.models import Service

# Keys must match what Safe Web / CGW send as `serviceKey` / path segment.
DEFAULTS = [
    ("WALLET_WEB", "Safe Wallet Web", "Browser wallet (v2 /v2/chains?serviceKey=…)"),
    ("CGW", "Client Gateway", "Safe Client Gateway"),
    ("frontend", "Frontend", "Legacy / generic frontend key"),
]

created = []
for key, name, description in DEFAULTS:
    _, was_created = Service.objects.get_or_create(
        key=key, defaults={"name": name, "description": description}
    )
    if was_created:
        created.append(key)

if created:
    print("seed_cfg_services: created:", ", ".join(created))
else:
    print("seed_cfg_services: all services already present")
PY
