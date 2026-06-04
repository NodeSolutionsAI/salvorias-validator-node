#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-salvorias-validator}"
KEY_NAME="${KEY_NAME:-validator}"
HOME_DIR="${HOME_DIR:-/home/evmos/.evmosd}"
DENOM="${DENOM:-SAVDR}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container is not running: $CONTAINER_NAME"
  docker ps -a --filter "name=$CONTAINER_NAME"
  exit 1
fi

echo "Docker:"
docker ps --filter "name=$CONTAINER_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
echo

echo "Sync:"
docker exec "$CONTAINER_NAME" sh -lc "curl -s http://127.0.0.1:26657/status | jq '.result.sync_info'"
echo

echo "Addresses:"
docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech acc || true
docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech val || true
echo

ACCOUNT="$(docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech acc -a 2>/dev/null || true)"
if [[ -n "$ACCOUNT" ]]; then
  echo "Balance:"
  docker exec "$CONTAINER_NAME" evmosd query bank balances "$ACCOUNT" --home "$HOME_DIR" --node tcp://127.0.0.1:26657 --output json | jq --arg denom "$DENOM" '.balances // [] | map(select(.denom == $denom))'
fi
echo

echo "Consensus Pubkey:"
docker exec "$CONTAINER_NAME" evmosd tendermint show-validator --home "$HOME_DIR"
echo

echo "Recent logs:"
docker logs --tail 40 "$CONTAINER_NAME"
