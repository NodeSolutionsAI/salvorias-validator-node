#!/usr/bin/env bash
set -euo pipefail

CONTAINER_NAME="${CONTAINER_NAME:-salvorias-validator}"
KEY_NAME="${KEY_NAME:-validator}"
HOME_DIR="${HOME_DIR:-/home/evmos/.evmosd}"
CHAIN_ID="${CHAIN_ID:-salvorias_7282-1}"
DENOM="${DENOM:-SAVDR}"
MONIKER=""
SELF_DELEGATION="${SELF_DELEGATION:-1000000000000000000}"
COMMISSION_RATE="${COMMISSION_RATE:-0.10}"
COMMISSION_MAX_RATE="${COMMISSION_MAX_RATE:-0.20}"
COMMISSION_MAX_CHANGE_RATE="${COMMISSION_MAX_CHANGE_RATE:-0.01}"
MIN_SELF_DELEGATION="${MIN_SELF_DELEGATION:-1}"

usage() {
  cat <<EOF
Usage: $0 --moniker NAME [options]

Options:
  --moniker NAME              Validator moniker.
  --self-delegation AMOUNT    Base units to self-delegate. Default: $SELF_DELEGATION
  --container-name NAME       Default: $CONTAINER_NAME
  --key-name NAME             Default: $KEY_NAME
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --moniker) MONIKER="$2"; shift 2 ;;
    --self-delegation) SELF_DELEGATION="$2"; shift 2 ;;
    --container-name) CONTAINER_NAME="$2"; shift 2 ;;
    --key-name) KEY_NAME="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

if [[ -z "$MONIKER" ]]; then
  read -r -p "Validator moniker: " MONIKER
fi

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  echo "Container is not running: $CONTAINER_NAME" >&2
  exit 1
fi

SYNC_JSON="$(docker exec "$CONTAINER_NAME" sh -lc "curl -s http://127.0.0.1:26657/status | jq '.result.sync_info'")"
CATCHING_UP="$(printf '%s' "$SYNC_JSON" | jq -r '.catching_up | tostring')"
LATEST_BLOCK="$(printf '%s' "$SYNC_JSON" | jq -r '.latest_block_height // "unknown"')"

echo "============================================"
echo " Activate Salvorias Production Validator"
echo "============================================"
echo " Moniker:      $MONIKER"
echo " Container:    $CONTAINER_NAME"
echo " Key:          $KEY_NAME"
echo " Native denom: $DENOM"
echo " Sync:         catching_up=$CATCHING_UP latest_block=$LATEST_BLOCK"
echo

if [[ "$CATCHING_UP" != "false" ]]; then
  echo "Node is still catching up. Wait for catching_up=false before activating." >&2
  exit 1
fi

ACCOUNT="$(docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech acc -a)"
VALOPER="$(docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech val -a)"
PUBKEY="$(docker exec "$CONTAINER_NAME" evmosd tendermint show-validator --home "$HOME_DIR")"
BALANCE="$(docker exec "$CONTAINER_NAME" evmosd query bank balances "$ACCOUNT" --home "$HOME_DIR" --node tcp://127.0.0.1:26657 --output json | jq -r --arg denom "$DENOM" '.balances // [] | map(select(.denom == $denom)) | .[0].amount // "0"')"

echo "Account:  $ACCOUNT"
echo "Valoper:  $VALOPER"
echo "Balance:  $BALANCE $DENOM"
echo

REQUIRED=$((SELF_DELEGATION + 1))
if [[ "$BALANCE" =~ ^[0-9]+$ ]] && [[ "$BALANCE" -lt "$REQUIRED" ]]; then
  echo "Insufficient $DENOM balance for self-delegation and fees." >&2
  echo "Fund $ACCOUNT before activating." >&2
  exit 1
fi

TMP_JSON="$(mktemp)"
cat > "$TMP_JSON" <<EOF
{
  "pubkey": $PUBKEY,
  "amount": "${SELF_DELEGATION}${DENOM}",
  "moniker": "$MONIKER",
  "identity": "",
  "website": "",
  "security": "",
  "details": "Salvorias production validator",
  "commission-rate": "$COMMISSION_RATE",
  "commission-max-rate": "$COMMISSION_MAX_RATE",
  "commission-max-change-rate": "$COMMISSION_MAX_CHANGE_RATE",
  "min-self-delegation": "$MIN_SELF_DELEGATION"
}
EOF

docker cp "$TMP_JSON" "$CONTAINER_NAME:/tmp/create-validator.json" >/dev/null
rm -f "$TMP_JSON"

echo "Submitting create-validator transaction..."
set +e
TX_OUT="$(docker exec "$CONTAINER_NAME" evmosd tx staking create-validator /tmp/create-validator.json \
  --from "$KEY_NAME" \
  --keyring-backend test \
  --home "$HOME_DIR" \
  --chain-id "$CHAIN_ID" \
  --node tcp://127.0.0.1:26657 \
  --gas 500000 \
  --gas-prices "0${DENOM}" \
  --yes \
  --output json 2>&1)"
TX_CODE=$?
set -e

printf '%s\n' "$TX_OUT" | jq . 2>/dev/null || printf '%s\n' "$TX_OUT"

if [[ "$TX_CODE" -ne 0 ]] || printf '%s' "$TX_OUT" | grep -qiE '"code":[1-9]|insufficient|not.*whitelist|unauthorized'; then
  echo
  echo "Create-validator did not succeed."
  echo "Check that the account is funded, whitelisted, and that this image is the current SAVDR production image."
  exit 1
fi

echo
echo "Validator activation transaction submitted."
echo "Check status with:"
echo "  docker exec $CONTAINER_NAME evmosd query staking validator $VALOPER --node tcp://127.0.0.1:26657"
