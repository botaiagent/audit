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
