# ME Smart Contract Security Harness

Foundry-based unit, fuzz, and invariant tests for the ME bonding-curve token.

> Status: scaffold only until the exact audited contract is added at `src/ME.sol`. No test result should be treated as a security certification.

## Requirements
- Foundry (Forge)
- Solidity compiler 0.8.24
- OpenZeppelin Contracts 5.x

## Setup
```bash
forge install foundry-rs/forge-std --no-commit
forge install OpenZeppelin/openzeppelin-contracts@v5.0.2 --no-commit
forge test -vvv
forge test --match-path 'test/invariant/*' --fuzz-runs 1000 -vvv
```

Place the exact contract under audit at `src/ME.sol`. Tests target the public interface seen in the reviewed ME source: `buyME(uint256,uint256)`, `sellME(uint256,uint256,uint256)`, `quoteBuy(uint256)`, `quoteSell(uint256)`, `reserveMON()`, `remainingME()`, `reserveSolvent()`, `TOTAL_SUPPLY()`, `surplusMON()`, and `rescueSurplusMON(address)`.

## CI and reports
GitHub Actions runs Forge tests on pushes and pull requests and uploads logs as workflow artifacts. Optional Railway webhook reporting is enabled by setting repository secret `RAILWAY_REPORT_WEBHOOK` to an HTTPS endpoint you control. The workflow sends run metadata; never place private keys in this repository.

## Security scope
This harness is a starting point, not a complete audit. Extend it with malicious receiver contracts, forced-MON tests, fee-accounting checks, quote/execution consistency, authorization tests, and economic simulations. Review the contract and test assumptions before relying on results.

## Testnet deployment rehearsal

A chain-ID-guarded Foundry script is available at `script/Deploy.s.sol`. It does not contain a private key or RPC endpoint. Use a throwaway testnet wallet funded only with test tokens; never use a mainnet key for rehearsal.

Set environment variables locally (do not commit them):
```bash
export RPC_URL="https://<your-testnet-rpc>"
export PRIVATE_KEY="<testnet-only-deployer-private-key>"
export EXPECTED_CHAIN_ID="<exact-chain-id>"
forge script script/Deploy.s.sol:DeployME \
  --rpc-url "$RPC_URL" \
  --broadcast
```

Before broadcasting, independently verify the RPC endpoint's chain ID against the intended testnet. The script reverts unless `block.chainid == EXPECTED_CHAIN_ID`. The deployer becomes the initial owner; after deployment, verify the address and bytecode, run the smoke tests, then transfer ownership to the intended multisig using the two-step ownership flow. Do not transfer ownership until the pending owner address is verified.

This repository change prepares the deployment procedure only. It does not mean a testnet deployment has occurred. A real deployment requires the operator to configure a trusted RPC endpoint and use their own wallet locally or via secured CI secrets.

### Monad Testnet preflight and smoke check

Monad Testnet currently uses chain ID `10143`, native currency `MON`, and 18 native-token decimals. Confirm the chain ID from your own configured RPC before any broadcast; do not rely on a hostname alone. See the Monad network reference: https://monad.xyz and testnet network details at https://monad.docsbot.app/ai/current-facts.

Copy `.env.example` to a local `.env` and fill it only on your own machine. Keep `.env` out of Git. Do not put a private key in chat, source files, or committed workflow YAML.

Read-only RPC preflight:
```bash
source .env
cast chain-id --rpc-url "$RPC_URL"
cast block-number --rpc-url "$RPC_URL"
```
Confirm the first command returns `10143` before proceeding. If it does not, stop.

Compile and run the existing suite before any deployment:
```bash
forge build
forge test -vvv
```

Only after the operator has confirmed the RPC, funded a dedicated testnet-only wallet with test MON, and reviewed the deployment bytecode should they choose to broadcast:
```bash
forge script script/Deploy.s.sol:DeployME --rpc-url "$RPC_URL" --broadcast
```

After deployment, set `ME_ADDRESS` to the transaction receipt's contract address and `EXPECTED_OWNER` to the expected owner address, then run the read-only smoke check:
```bash
forge script script/VerifyME.s.sol:VerifyME --rpc-url "$RPC_URL"
```
The verification script does not broadcast transactions. It checks chain ID, expected owner, fixed total supply, token metadata, and reserve solvency. Save the deployment transaction hash, address, compiler settings, and verified source/bytecode as the testnet record.

No testnet deployment is implied by these instructions or repository files; deployment must be initiated and authorized by the operator.
