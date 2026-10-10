// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ME} from "../src/ME.sol";

/// @notice Sends a small real buy and full-sell round trip on Monad Testnet only.
contract TestnetTrade is Script {
    error WrongChain(uint256 expected, uint256 actual);
    error InvalidTradeAmount();
    error BuyReturnedNoTokens();
    error SolvencyCheckFailed();

    function run() external {
        uint256 expectedChainId = vm.envUint("EXPECTED_CHAIN_ID");
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address meAddress = vm.envAddress("ME_ADDRESS");
        uint256 tradeAmount = 0.02 ether;

        if (block.chainid != expectedChainId) {
            revert WrongChain(expectedChainId, block.chainid);
        }
        if (expectedChainId != 10143) {
            revert WrongChain(10143, expectedChainId);
        }
        if (tradeAmount < 0.01 ether) revert InvalidTradeAmount();

        ME me = ME(payable(meAddress));
        address trader = vm.addr(deployerKey);

        if (meAddress.code.length == 0) revert SolvencyCheckFailed();
        if (!me.reserveSolvent()) revert SolvencyCheckFailed();

        uint256 startingBalance = me.balanceOf(trader);
        uint256 buyQuote = me.quoteBuy(tradeAmount);
        if (buyQuote == 0) revert BuyReturnedNoTokens();

        vm.startBroadcast(deployerKey);
        me.buyME{value: tradeAmount}(buyQuote, block.timestamp + 15 minutes);

        uint256 bought = me.balanceOf(trader) - startingBalance;
        if (bought == 0) revert BuyReturnedNoTokens();

        uint256 sellQuote = me.quoteSellFor(trader, bought);
        me.sellME(bought, sellQuote, block.timestamp + 15 minutes);
        vm.stopBroadcast();

        if (!me.reserveSolvent()) revert SolvencyCheckFailed();
        if (me.balanceOf(trader) != startingBalance) revert SolvencyCheckFailed();

        console2.log("Testnet round trip completed");
        console2.log("Chain ID:", block.chainid);
        console2.log("ME contract:", meAddress);
        console2.log("Trader:", trader);
        console2.log("MON spent on buy (wei):", tradeAmount);
        console2.log("ME bought and sold (wei):", bought);
        console2.log("Quoted MON returned (wei):", sellQuote);
        console2.log("Reserve solvent:", me.reserveSolvent());
        console2.log("Trader ME balance restored:", me.balanceOf(trader) == startingBalance);
    }
}
