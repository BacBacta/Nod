#!/usr/bin/env bash
# Local dev chain for the frontend: anvil + full Nod stack + a seeded demo token.
# LOCAL ONLY. Uses anvil's public default keys. Never point this at Arc.
set -euo pipefail
cd "$(dirname "$0")/.."

RPC=http://127.0.0.1:8545

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "Starting anvil on $RPC ..."
  anvil --chain-id 31337 --silent >/dev/null 2>&1 &
  for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.1; done
fi

forge script contracts/script/DevLocal.s.sol --rpc-url "$RPC" --broadcast --silent

# Skip IdentityAttestor's 7-day first-claim cooldown so the creator can accept now.
cast rpc evm_increaseTime 604801 --rpc-url "$RPC" >/dev/null
cast rpc evm_mine --rpc-url "$RPC" >/dev/null

node scripts/sync-abis.mjs
echo "Local stack ready. Addresses: frontend/src/deployments/31337.json"
