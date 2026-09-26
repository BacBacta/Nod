#!/usr/bin/env bash
# Local attestation service for the frontend, against the anvil stack from dev-local.sh.
# LOCAL ONLY: signs with anvil's public key #0 and simulates OAuth (DEV_FAKE_OAUTH).
set -euo pipefail
cd "$(dirname "$0")/.."

ATTESTOR=$(node -e 'console.log(require("./frontend/src/deployments/31337.json").attestor)')

cd attestation-service
PORT=8787 \
PUBLIC_URL=http://localhost:8787 \
FRONTEND_URL="${FRONTEND_URL:-http://localhost:5173}" \
RPC_URL=http://127.0.0.1:8545 \
CHAIN_ID=31337 \
ATTESTOR_ADDRESS="$ATTESTOR" \
ATTESTER_PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
FARCASTER_ENABLED="${FARCASTER_ENABLED:-false}" \
DEV_FAKE_OAUTH=true \
exec npx tsx src/server.ts
