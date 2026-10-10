#!/usr/bin/env bash
set -euo pipefail

# Generate a fresh wallet locally for Monad Testnet testing.
# IMPORTANT: Run on your own trusted device, NOT in GitHub Actions.
# Never commit or upload the private key or seed phrase.

if ! command -v cast >/dev/null 2>&1; then
  echo "Foundry 'cast' is required. Install Foundry first: https://getfoundry.sh/"
  exit 1
fi

echo "Generating a new local test wallet..."
echo "Keep the private key secret. Do not paste it into GitHub, chat, or issue trackers."
cast wallet new
echo
echo "Network details:"
echo "  Network: Monad Testnet"
echo "  Chain ID: 10143"
echo "  RPC: https://testnet-rpc.monad.xyz"
echo "  Explorer: https://testnet.monadscan.com/"
echo
echo "This script only creates a wallet locally; it does not fund it or buy ME."
