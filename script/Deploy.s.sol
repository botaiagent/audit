// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ME} from "../src/ME.sol";

/// @notice Guarded deployment script. Requires explicit expected chain ID.
contract DeployME is Script {
    error WrongChain(uint256 expected, uint256 actual);
    error UnsafeOwner(address deployer);

    function run() external returns (ME deployed) {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        address deployer = vm.addr(deployerKey);
        if (block.chainid != expectedChainId) {
            revert WrongChain(expectedChainId, block.chainid);
        }
        if (deployer == address(0)) revert UnsafeOwner(deployer);

        vm.startBroadcast(deployerKey);
        deployed = new ME();
        vm.stopBroadcast();

        console2.log("ME deployed at:", address(deployed));
        console2.log("Chain ID:", block.chainid);
        console2.log("Initial owner/deployer:", deployed.owner());
        console2.log("Total supply:", deployed.totalSupply());
        console2.log("Reserve solvent:", deployed.reserveSolvent());
    }
}
