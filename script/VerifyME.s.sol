// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ME} from "../src/ME.sol";

/// @notice Read-only post-deployment smoke check; sends no transactions.
contract VerifyME is Script {
    error WrongChain(uint256 expected, uint256 actual);
    error WrongOwner(address expected, address actual);
    error WrongSupply(uint256 expected, uint256 actual);
    error InsolventReserve();
    error UnexpectedTokenMetadata();

    function run() external view returns (bool ok) {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        address deployedAddress = vm.envAddress("ME_ADDRESS");
        address expectedOwner = vm.envAddress("EXPECTED_OWNER");

        if (block.chainid != expectedChainId) {
            revert WrongChain(expectedChainId, block.chainid);
        }

        ME deployed = ME(payable(deployedAddress));
        address actualOwner = deployed.owner();
        if (actualOwner != expectedOwner) {
            revert WrongOwner(expectedOwner, actualOwner);
        }
        if (deployed.totalSupply() != deployed.TOTAL_SUPPLY()) {
            revert WrongSupply(deployed.TOTAL_SUPPLY(), deployed.totalSupply());
        }
        if (
            keccak256(bytes(deployed.name())) != keccak256(bytes("ME")) ||
            keccak256(bytes(deployed.symbol())) != keccak256(bytes("ME")) ||
            deployed.decimals() != 18
        ) {
            revert UnexpectedTokenMetadata();
        }
        if (!deployed.reserveSolvent()) revert InsolventReserve();

        console2.log("ME address:", deployedAddress);
        console2.log("Chain ID:", block.chainid);
        console2.log("Owner:", actualOwner);
        console2.log("Total supply:", deployed.totalSupply());
        console2.log("Remaining ME:", deployed.remainingME());
        console2.log("Reserve MON:", deployed.reserveMON());
        console2.log("Accrued owner fees:", deployed.accruedOwnerFees());
        console2.log("Curve K:", deployed.curveK());
        console2.log("Reserve solvent:", deployed.reserveSolvent());
        return true;
    }
}
