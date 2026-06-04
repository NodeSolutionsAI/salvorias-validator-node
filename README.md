# Salvorias Validator Handoff

This repo is the lightweight production validator onboarding package for Salvorias. It lets an operator start a production validator host without cloning the full chain development repo.

It does three things:

1. Pulls the Salvorias validator Docker image.
2. Imports or creates the validator mnemonic/key.
3. Configures state sync and starts the validator container.

No mnemonic is committed or stored in this repo.

## Requirements

- Ubuntu server with Docker installed.
- Ports:
  - `26656/tcp` open publicly for P2P.
  - SSH open only to trusted operator IPs.
- A funded and whitelisted validator account before activation.

## Quick Start On The Validator Host

Run these commands on the validator server:

```bash
git clone https://github.com/NodeSolutionsAI/salvorias-validator-node.git
cd salvorias-validator-node

chmod +x scripts/*.sh

./scripts/onboard-validator.sh \
  --moniker "SaveMarket" \
  --external-ip "YOUR_SERVER_PUBLIC_IP"
```

During onboarding, paste the validator mnemonic when prompted. If you press enter without a mnemonic, the script will create a new validator key and print the mnemonic once.

After onboarding finishes, send the printed `Account`, `Valoper`, and `Consensus Pubkey` to the Salvorias operator team for funding and validator whitelist/governance.

## Check Sync

```bash
./scripts/status.sh
```

The validator is ready to activate only when:

```text
catching_up: false
```

## Activate Validator

After the account is funded and whitelisted:

```bash
./scripts/activate-validator.sh \
  --moniker "SaveMarket"
```

Default self-delegation is `1 SAVDR`. You can override it:

```bash
./scripts/activate-validator.sh \
  --moniker "SaveMarket" \
  --self-delegation 5000000000000000000
```

The self-delegation amount is in base units. `1000000000000000000` equals `1 SAVDR`.

## Defaults

- EVM chain ID: `7282`
- Cosmos chain ID: `salvorias_7282-1`
- Native denom: `SAVDR`
- Container name: `salvorias-validator`
- Docker volume: `salvorias-validator-data`
- Image: `ghcr.io/nodesolutionsai/salvorias-validator-node:latest`
- State sync RPC: `http://134.199.216.166:26660`

## Useful Commands

Tail logs:

```bash
docker logs -f --tail 200 salvorias-validator
```

Show node sync state:

```bash
docker exec salvorias-validator curl -s http://127.0.0.1:26657/status | jq '.result.sync_info'
```

Show validator addresses:

```bash
docker exec salvorias-validator evmosd keys show validator \
  --keyring-backend test \
  --home /home/evmos/.evmosd \
  --bech acc

docker exec salvorias-validator evmosd keys show validator \
  --keyring-backend test \
  --home /home/evmos/.evmosd \
  --bech val
```

## Publishing The Image

For maintainers:

```bash
./scripts/publish-image.sh
```

This tags the local production image as `ghcr.io/nodesolutionsai/salvorias-validator-node:latest` and pushes it to GitHub Container Registry.
