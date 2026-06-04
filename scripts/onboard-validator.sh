#!/usr/bin/env bash
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/nodesolutionsai/salvorias-validator-node:latest}"
IMAGE_TARBALL_URL="${IMAGE_TARBALL_URL:-https://github.com/NodeSolutionsAI/salvorias-validator-node/releases/latest/download/salvorias-validator-node-latest.tar.gz}"
CONTAINER_NAME="${CONTAINER_NAME:-salvorias-validator}"
VOLUME_NAME="${VOLUME_NAME:-salvorias-validator-data}"
KEY_NAME="${KEY_NAME:-validator}"
CHAIN_ID="${CHAIN_ID:-salvorias_7282-1}"
EVM_CHAIN_ID="${EVM_CHAIN_ID:-7282}"
DENOM="${DENOM:-SAVDR}"
STATE_SYNC_RPC="${STATE_SYNC_RPC:-http://134.199.216.166:26660}"
PERSISTENT_PEERS="${PERSISTENT_PEERS:-bc9decb51c24982322c756b7c9a0c837ed7a7216@134.199.216.166:26656,7883bda6e4de7db2b7056ead781a0a6383bd31c8@45.32.168.97:26656,a98ef2a79329ebdd7fee7d546ec284b64e7306fb@64.23.236.42:26656}"
HOME_DIR="/home/evmos/.evmosd"
MONIKER=""
EXTERNAL_IP=""
MNEMONIC=""
MNEMONIC_FILE=""
FORCE="false"

usage() {
  cat <<EOF
Usage: $0 --moniker NAME --external-ip IP [options]

Options:
  --moniker NAME          Validator moniker.
  --external-ip IP        Public IP advertised for P2P.
  --mnemonic-file PATH    Read validator mnemonic from file.
  --mnemonic "WORDS"      Pass mnemonic directly. Prefer --mnemonic-file or prompt.
  --image IMAGE           Docker image. Default: $IMAGE
  --force                 Remove existing container before starting.
  -h, --help              Show this help.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --moniker) MONIKER="$2"; shift 2 ;;
    --external-ip) EXTERNAL_IP="$2"; shift 2 ;;
    --mnemonic-file) MNEMONIC_FILE="$2"; shift 2 ;;
    --mnemonic) MNEMONIC="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    --force) FORCE="true"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; usage; exit 1 ;;
  esac
done

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

need_cmd docker
need_cmd curl
need_cmd jq

if [[ -z "$MONIKER" ]]; then
  read -r -p "Validator moniker: " MONIKER
fi

if [[ -z "$EXTERNAL_IP" ]]; then
  DETECTED_IP="$(curl -fsS --max-time 10 https://ifconfig.me 2>/dev/null || true)"
  read -r -p "External public IP [${DETECTED_IP}]: " EXTERNAL_IP
  EXTERNAL_IP="${EXTERNAL_IP:-$DETECTED_IP}"
fi

if [[ -z "$MONIKER" || -z "$EXTERNAL_IP" ]]; then
  echo "moniker and external-ip are required." >&2
  exit 1
fi

if [[ -n "$MNEMONIC_FILE" ]]; then
  MNEMONIC="$(tr '\n' ' ' < "$MNEMONIC_FILE" | sed 's/[[:space:]]*$//')"
fi

echo "============================================"
echo " Salvorias Validator Onboarding"
echo "============================================"
echo " Moniker:       $MONIKER"
echo " External IP:   $EXTERNAL_IP"
echo " Image:         $IMAGE"
echo " Chain ID:      $CHAIN_ID"
echo " Native denom:  $DENOM"
echo " State sync:    $STATE_SYNC_RPC"
echo

if ! docker pull "$IMAGE"; then
  echo
  echo "Docker registry pull failed for $IMAGE."
  echo "Falling back to release image tarball:"
  echo "  $IMAGE_TARBALL_URL"
  TMP_IMAGE="$(mktemp -t salvorias-validator-image.XXXXXX.tar.gz)"
  curl -fL --retry 3 --retry-delay 3 -o "$TMP_IMAGE" "$IMAGE_TARBALL_URL"
  docker load -i "$TMP_IMAGE"
  rm -f "$TMP_IMAGE"
fi

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
  if [[ "$FORCE" == "true" ]]; then
    docker rm -f "$CONTAINER_NAME" >/dev/null
  else
    echo "Container already exists: $CONTAINER_NAME"
    echo "Use --force to replace it, or run ./scripts/status.sh to inspect it."
    exit 1
  fi
fi

docker volume create "$VOLUME_NAME" >/dev/null

SETUP_CONTAINER="${CONTAINER_NAME}-setup-$$"
cleanup() {
  docker rm -f "$SETUP_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$SETUP_CONTAINER" \
  -v "$VOLUME_NAME:$HOME_DIR" \
  --entrypoint sleep \
  "$IMAGE" infinity >/dev/null

echo "Fetching genesis from state-sync RPC..."
GENESIS_FILE="$(mktemp)"
curl -fsS "$STATE_SYNC_RPC/genesis" | jq '.result.genesis' > "$GENESIS_FILE"
docker cp "$GENESIS_FILE" "$SETUP_CONTAINER:/tmp/genesis.json"
rm -f "$GENESIS_FILE"

echo "Initializing node home..."
docker exec "$SETUP_CONTAINER" sh -lc "
  rm -rf '$HOME_DIR/config' '$HOME_DIR/data'
  evmosd init '$MONIKER' --chain-id '$CHAIN_ID' --home '$HOME_DIR' >/dev/null
  cp /tmp/genesis.json '$HOME_DIR/config/genesis.json'
  evmosd config chain-id '$CHAIN_ID' --home '$HOME_DIR'
  evmosd config keyring-backend test --home '$HOME_DIR'
"

if [[ -z "$MNEMONIC" ]]; then
  echo
  echo "Paste existing validator mnemonic and press enter."
  echo "Leave blank to create a new validator key."
  read -r -s -p "Mnemonic: " MNEMONIC
  echo
fi

if [[ -n "$MNEMONIC" ]]; then
  echo "Importing validator key..."
  printf '%s\n' "$MNEMONIC" | docker exec -i "$SETUP_CONTAINER" sh -lc "
    evmosd keys add '$KEY_NAME' \
      --recover \
      --algo eth_secp256k1 \
      --keyring-backend test \
      --home '$HOME_DIR' >/tmp/key.out
    cat /tmp/key.out
  "
else
  echo "Creating new validator key. Save this mnemonic now; it will not be printed again."
  docker exec "$SETUP_CONTAINER" sh -lc "
    evmosd keys add '$KEY_NAME' \
      --algo eth_secp256k1 \
      --keyring-backend test \
      --home '$HOME_DIR'
  "
fi

echo "Configuring state sync..."
LATEST="$(curl -fsS "$STATE_SYNC_RPC/status" | jq -r '.result.sync_info.latest_block_height')"
TRUST_HEIGHT=$((LATEST - 2000))
if [[ "$TRUST_HEIGHT" -lt 1 ]]; then
  TRUST_HEIGHT=1
fi
TRUST_HASH="$(curl -fsS "$STATE_SYNC_RPC/commit?height=$TRUST_HEIGHT" | jq -r '.result.signed_header.commit.block_id.hash')"

docker exec "$SETUP_CONTAINER" sh -lc "
  CFG='$HOME_DIR/config/config.toml'
  APP='$HOME_DIR/config/app.toml'

  sed -i 's|^moniker = .*|moniker = \"'$MONIKER'\"|' \"\$CFG\"
  sed -i 's|^external_address = .*|external_address = \"'$EXTERNAL_IP':26656\"|' \"\$CFG\"
  sed -i 's|^persistent_peers = .*|persistent_peers = \"'$PERSISTENT_PEERS'\"|' \"\$CFG\"
  sed -i 's|^addr_book_strict = .*|addr_book_strict = false|' \"\$CFG\"

  sed -i '/^\\[statesync\\]/,/^\\[/ s|^enable = .*|enable = true|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^rpc_servers = .*|rpc_servers = \"'$STATE_SYNC_RPC','$STATE_SYNC_RPC'\"|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_height = .*|trust_height = '$TRUST_HEIGHT'|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_hash = .*|trust_hash = \"'$TRUST_HASH'\"|' \"\$CFG\"
  sed -i '/^\\[statesync\\]/,/^\\[/ s|^trust_period = .*|trust_period = \"168h0m0s\"|' \"\$CFG\"

  sed -i 's|^minimum-gas-prices = .*|minimum-gas-prices = \"0'$DENOM'\"|' \"\$APP\"
  sed -i '/^\\[api\\]/,/^\\[/ s|^enable = .*|enable = true|' \"\$APP\"
  sed -i '/^\\[api\\]/,/^\\[/ s|^swagger = .*|swagger = true|' \"\$APP\"
  sed -i '/^\\[rosetta\\]/,/^\\[/ s|^enable = .*|enable = false|' \"\$APP\"
"

echo "Starting validator container..."
docker stop "$SETUP_CONTAINER" >/dev/null
docker rm "$SETUP_CONTAINER" >/dev/null
trap - EXIT

docker run -d \
  --name "$CONTAINER_NAME" \
  --restart unless-stopped \
  -v "$VOLUME_NAME:$HOME_DIR" \
  -p 26656:26656 \
  -p 127.0.0.1:26657:26657 \
  -p 127.0.0.1:1317:1317 \
  -p 127.0.0.1:8545:8545 \
  -p 127.0.0.1:8546:8546 \
  -p 127.0.0.1:9090:9090 \
  "$IMAGE" evmosd start --home "$HOME_DIR" >/dev/null

sleep 5

echo
echo "Validator container started."
echo
echo "Account:"
docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech acc
echo
echo "Valoper:"
docker exec "$CONTAINER_NAME" evmosd keys show "$KEY_NAME" --keyring-backend test --home "$HOME_DIR" --bech val
echo
docker exec "$CONTAINER_NAME" evmosd tendermint show-validator --home "$HOME_DIR" | sed 's/^/Consensus Pubkey: /'
NODE_ID="$(docker exec "$CONTAINER_NAME" evmosd tendermint show-node-id --home "$HOME_DIR")"
echo "Node ID: $NODE_ID"
echo "Peer: ${NODE_ID}@${EXTERNAL_IP}:26656"
echo
echo "Sync status:"
docker exec "$CONTAINER_NAME" sh -lc "curl -s http://127.0.0.1:26657/status | jq '.result.sync_info'"
echo
echo "Next:"
echo "  1. Send Account, Valoper, Consensus Pubkey, and Peer to the Salvorias operator."
echo "  2. Wait for funding and whitelist approval."
echo "  3. Run ./scripts/status.sh until catching_up is false."
echo "  4. Run ./scripts/activate-validator.sh --moniker \"$MONIKER\""
