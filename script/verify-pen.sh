#!/usr/bin/env bash
# Full PEN verification: live state, then the log-based membership checks.
#
#   DEPLOYMENT_FILE=deployments/<chainId>.json FROM_BLOCK=<deploymentBlock> \
#     ./script/verify-pen.sh .env
#
# 1. VerifyPENSystem  - state verifier (README Step 9): bytecode, wiring, parameters, role
#                       holders, Safe owner / modules / guard, Space and exec-strategy config,
#                       proxy implementations, treasury solvency.
# 2. VerifyPENHistory - replays logs from FROM_BLOCK: complete role-holder census, Space
#                       configuration changes after creation, spaces enabled on the exec
#                       strategy, and a seat-holder census reconciled with totalSupply.
#
# Both are read-only `forge script` runs without --broadcast: nothing is signed or sent.
#
# Arguments:
#   $1               env file to load (default: .env). Needs RPC_URL and the config values.
# Environment:
#   FROM_BLOCK       required. The Phase 1 deploy block, or any block before it.
#   DEPLOYMENT_FILE  optional. Default: deployments/<connected-chain-id>.json
#   TO_BLOCK         optional. Default: latest block.
#   LOG_CHUNK        optional. Blocks per eth_getLogs request (default 10000). The scan
#                    halves it on its own if the RPC rejects a range.
#   DEPLOYER         optional. Also check that the deployer EOA kept no role or Safe seat.
#   FORGE            optional. Path to forge (default: forge on PATH).
#
# Exit code: 0 when both stages pass, 1 otherwise.

set -euo pipefail

ENV_FILE="${1:-.env}"
FORGE="${FORGE:-forge}"

# Run from the repository root so relative paths (deployments/, lib/) resolve.
cd "$(dirname "$0")/.."

if [ ! -f "$ENV_FILE" ]; then
  echo "verify-pen: env file not found: $ENV_FILE" >&2
  exit 1
fi

# Keep values that were set on the command line; .env only fills in the rest.
OVERRIDE_DEPLOYMENT_FILE="${DEPLOYMENT_FILE-}"
OVERRIDE_FROM_BLOCK="${FROM_BLOCK-}"
OVERRIDE_TO_BLOCK="${TO_BLOCK-}"
OVERRIDE_DEPLOYER="${DEPLOYER-}"

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

[ -n "$OVERRIDE_DEPLOYMENT_FILE" ] && export DEPLOYMENT_FILE="$OVERRIDE_DEPLOYMENT_FILE"
[ -n "$OVERRIDE_FROM_BLOCK" ] && export FROM_BLOCK="$OVERRIDE_FROM_BLOCK"
[ -n "$OVERRIDE_TO_BLOCK" ] && export TO_BLOCK="$OVERRIDE_TO_BLOCK"
[ -n "$OVERRIDE_DEPLOYER" ] && export DEPLOYER="$OVERRIDE_DEPLOYER"

# The verifiers never sign anything; keep the key out of their environment.
unset PRIVATE_KEY

if [ -z "${RPC_URL:-}" ]; then
  echo "verify-pen: RPC_URL is not set (in $ENV_FILE or the environment)" >&2
  exit 1
fi
if [ -z "${FROM_BLOCK:-}" ]; then
  echo "verify-pen: FROM_BLOCK is required (the Phase 1 deploy block)" >&2
  exit 1
fi

state_status=0
history_status=0

echo "=== 1/2 VerifyPENSystem (live state) ==="
"$FORGE" script script/VerifyPENSystem.s.sol:VerifyPENSystem --rpc-url "$RPC_URL" || state_status=$?

echo
echo "=== 2/2 VerifyPENHistory (logs from block $FROM_BLOCK) ==="
"$FORGE" script script/VerifyPENSystem.s.sol:VerifyPENHistory --rpc-url "$RPC_URL" || history_status=$?

echo
echo "=== verify-pen summary ==="
if [ "$state_status" -eq 0 ]; then echo "state:   PASS"; else echo "state:   FAIL"; fi
if [ "$history_status" -eq 0 ]; then echo "history: PASS"; else echo "history: FAIL"; fi

if [ "$state_status" -ne 0 ] || [ "$history_status" -ne 0 ]; then
  exit 1
fi
