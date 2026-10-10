// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 9: economic edge cases, curve manipulation and round-trip attacks.
/// @dev Local Foundry tests only. No RPC, wallet, or Testnet transaction.
contract MEEconomicAttackGate9Test is Test {
    ME internal me;
    address internal attacker = address(0xA771);
    address internal victim = address(0xB0B);
    address internal arbitrageur = address(0xA8B);

    function setUp() public {
        me = new ME();
        vm.deal(attacker, 10_000 ether);
        vm.deal(victim, 10_000 ether);
        vm.deal(arbitrageur, 10_000 ether);
    }

    function _buy(address who, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        out = me.buyME{value: amount}(0, block.timestamp + 1 days);
    }

    function _sellAll(address who) internal returns (uint256 out) {
        uint256 tokens = me.balanceOf(who);
        vm.prank(who);
        out = me.sellME(tokens, 0, block.timestamp + 1 days);
    }

    function _assertAccounting() internal view {
        assertTrue(me.reserveSolvent(), "reserve must cover all liabilities");
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees(), "unexpected unaccounted MON");
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY(), "fixed supply changed");
        assertEq(me.balanceOf(address(me)), me.remainingME(), "curve ledger mismatch");
        assertGe(me.curveK(), me.INITIAL_K(), "K below initial value");
        assertGe(me.virtualReserveMON() * me.remainingME(), me.curveK(), "curve point below K");
    }

    function test_BuyThenImmediateFullSellCannotProfit() public {
        uint256 startBalance = attacker.balance;
        uint256 bought = _buy(attacker, 10 ether);
        assertGt(bought, 0);

        uint256 returnedMON = _sellAll(attacker);
        assertLt(returnedMON, 10 ether, "round trip must pay fees / curve spread");
        assertLt(attacker.balance, startBalance, "attacker must not profit before gas");
        assertEq(me.balanceOf(attacker), 0, "attacker should fully exit");
        _assertAccounting();
    }

    function test_QuoteCannotBeUsedToBypassSlippageAfterPriceMoves() public {
        uint256 quoted = me.quoteBuy(5 ether);
        _buy(victim, 20 ether);

        uint256 reserveBefore = me.reserveMON();
        uint256 kBefore = me.curveK();
        uint256 attackerBalanceBefore = me.balanceOf(attacker);
        vm.prank(attacker);
        (bool ok,) = address(me).call{value: 5 ether}(
            abi.encodeCall(ME.buyME, (quoted, block.timestamp + 1 days))
        );
        assertFalse(ok, "stale quote with minOut must revert after price moves");
        assertEq(me.reserveMON(), reserveBefore, "reverted buy changed reserve");
        assertEq(me.curveK(), kBefore, "reverted buy changed K");
        assertEq(me.balanceOf(attacker), attackerBalanceBefore, "reverted buy changed token balance");
        _assertAccounting();
    }

    function test_SequentialBuysDoNotDecreaseMarginalPriceOrK() public {
        uint256 price0 = me.currentPrice();
        uint256 k0 = me.curveK();

        _buy(attacker, 3 ether);
        uint256 price1 = me.currentPrice();
        uint256 k1 = me.curveK();
        _buy(victim, 7 ether);
        uint256 price2 = me.currentPrice();

        assertGe(price1, price0, "price fell after buy");
        assertGe(price2, price1, "price fell after second buy");
        assertGe(k1, k0, "K fell after first buy");
        assertGe(me.curveK(), k1, "K fell after second buy");
        _assertAccounting();
    }

    function test_RepeatedBuySellCyclesDoNotCreateFreeMON() public {
        uint256 startBalance = arbitrageur.balance;

        for (uint256 i; i < 5; ++i) {
            _buy(arbitrageur, 1 ether);
            _sellAll(arbitrageur);
            _assertAccounting();
        }

        assertLt(arbitrageur.balance, startBalance, "repeated round trips must not create MON");
        assertGe(me.curveK(), me.INITIAL_K(), "K must not regress across cycles");
    }

    function test_SplitTradesAndSingleTradeBothRemainSolvent() public {
        // Compare two trading paths from equivalent initial deployments.
        ME split = new ME();
        ME single = new ME();
        vm.deal(attacker, 100 ether);
        vm.deal(victim, 100 ether);

        vm.prank(attacker);
        split.buyME{value: 2 ether}(0, block.timestamp + 1 days);
        vm.prank(attacker);
        split.buyME{value: 2 ether}(0, block.timestamp + 1 days);

        vm.prank(victim);
        single.buyME{value: 4 ether}(0, block.timestamp + 1 days);

        assertTrue(split.reserveSolvent(), "split path insolvent");
        assertTrue(single.reserveSolvent(), "single path insolvent");
        assertEq(address(split).balance, split.reserveMON() + split.accruedOwnerFees());
        assertEq(address(single).balance, single.reserveMON() + single.accruedOwnerFees());
        assertGe(split.curveK(), split.INITIAL_K());
        assertGe(single.curveK(), single.INITIAL_K());
        assertEq(split.totalSupply(), split.TOTAL_SUPPLY());
        assertEq(single.totalSupply(), single.TOTAL_SUPPLY());
    }

    function testFuzz_RoundTripNeverReturnsMoreThanGrossInput(uint96 rawInput) public {
        uint256 amount = bound(uint256(rawInput), me.MIN_TRADE_MON(), 100 ether);
        uint256 beforeBalance = attacker.balance;

        _buy(attacker, amount);
        uint256 returnedMON = _sellAll(attacker);

        assertLe(returnedMON, amount, "round trip returned more than gross input");
        assertLt(attacker.balance, beforeBalance, "round trip must not increase trader balance");
        _assertAccounting();
    }

    function testFuzz_AnySuccessfulBuyKeepsReserveAndSupplyConsistent(uint96 rawInput) public {
        uint256 amount = bound(uint256(rawInput), me.MIN_TRADE_MON(), 100 ether);
        _buy(attacker, amount);
        _assertAccounting();
        assertGt(me.balanceOf(attacker), 0, "successful buy should deliver ME");
        assertLt(me.remainingME(), me.TOTAL_SUPPLY(), "remaining supply did not decrease");
    }
}
