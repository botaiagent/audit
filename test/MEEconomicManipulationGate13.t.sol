// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 13: price impact, sandwich-style ordering and economic invariants.
/// @dev Local Foundry only. No live-chain writes or deployment.
contract MEEconomicManipulationGate13Test is Test {
    ME internal me;
    address internal trader = address(0xA11CE);
    address internal victim = address(0xB0B);
    address internal attacker = address(0xA771);

    function setUp() public {
        me = new ME();
        vm.deal(trader, 1_000 ether);
        vm.deal(victim, 1_000 ether);
        vm.deal(attacker, 1_000 ether);
    }

    function _buy(address who, uint256 amount, uint256 minOut) internal returns (uint256 out) {
        vm.prank(who);
        out = me.buyME{value: amount}(minOut, block.timestamp + 1 days);
    }

    function _sellAll(address who, uint256 minOut) internal returns (uint256 out) {
        uint256 amount = me.balanceOf(who);
        vm.prank(who);
        out = me.sellME(amount, minOut, block.timestamp + 1 days);
    }

    function _assertAccounting() internal view {
        assertTrue(me.reserveSolvent(), "insolvent liabilities");
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees() + me.surplusMON());
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
        assertEq(me.balanceOf(address(me)), me.remainingME());
        assertGe(me.curveK(), me.INITIAL_K());
        assertGe(me.virtualReserveMON() * me.remainingME(), me.curveK());
    }

    function test_BuyImpactRaisesPriceAndReducesLaterBuyerOutput() public {
        uint256 initialPrice = me.currentPrice();
        uint256 smallQuoteBefore = me.quoteBuy(5 ether);

        _buy(attacker, 50 ether, 0);
        uint256 priceAfterLargeBuy = me.currentPrice();
        uint256 smallQuoteAfter = me.quoteBuy(5 ether);

        assertGt(priceAfterLargeBuy, initialPrice, "large buy should raise marginal price");
        assertLt(smallQuoteAfter, smallQuoteBefore, "same input should buy fewer ME after price impact");
        _assertAccounting();
    }

    function test_VictimMinOutProtectsAgainstAdversePrecedingBuy() public {
        uint256 victimQuote = me.quoteBuy(10 ether);
        _buy(attacker, 100 ether, 0);

        uint256 reserveBefore = me.reserveMON();
        uint256 kBefore = me.curveK();
        uint256 victimBalanceBefore = me.balanceOf(victim);

        vm.prank(victim);
        vm.expectRevert(ME.SlippageExceeded.selector);
        me.buyME{value: 10 ether}(victimQuote, block.timestamp + 1 days);

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.balanceOf(victim), victimBalanceBefore);
        _assertAccounting();
    }

    function test_SandwichLikeBuyThenVictimBuyThenSellLosesToFees() public {
        uint256 attackerStart = attacker.balance;

        _buy(attacker, 20 ether, 0);
        uint256 victimOut = _buy(victim, 20 ether, 0);
        assertGt(victimOut, 0);
        _sellAll(attacker, 0);

        assertLt(attacker.balance, attackerStart, "round trip must not profit in this no-external-market model");
        _assertAccounting();
    }

    function test_SellImpactLowersPriceAndReducesLaterSellQuote() public {
        _buy(trader, 100 ether, 0);
        _buy(attacker, 100 ether, 0);

        uint256 victimTokens = me.balanceOf(trader) / 4;
        uint256 quoteBefore = me.quoteSellFor(trader, victimTokens);

        _sellAll(attacker, 0);
        uint256 quoteAfter = me.quoteSellFor(trader, victimTokens);

        assertLt(me.currentPrice(), me.BASE_MON() * 1 ether / me.TOTAL_SUPPLY() + 1e18, "sanity: price remains finite");
        assertLe(quoteAfter, quoteBefore, "earlier sell should not improve later sell quote");
        _assertAccounting();
    }

    function test_ClaimFeesAndForcedSurplusDoNotChangeTradeQuote() public {
        _buy(trader, 10 ether, 0);
        uint256 quoteBefore = me.quoteBuy(3 ether);
        uint256 reserveBefore = me.reserveMON();
        uint256 kBefore = me.curveK();

        me.claimOwnerFees(payable(address(0xFEE)));
        assertEq(me.quoteBuy(3 ether), quoteBefore);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.curveK(), kBefore);

        vm.deal(address(me), address(me).balance + 2 ether);
        uint256 quoteWithSurplus = me.quoteBuy(3 ether);
        me.rescueSurplusMON(address(0xFEE));
        assertEq(me.quoteBuy(3 ether), quoteWithSurplus);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.curveK(), kBefore);
        _assertAccounting();
    }

    function testFuzz_SuccessfulBuyNeverReducesPriceOrK(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 100 ether);
        uint256 priceBefore = me.currentPrice();
        uint256 kBefore = me.curveK();

        _buy(trader, amount, 0);

        assertGe(me.currentPrice(), priceBefore);
        assertGe(me.curveK(), kBefore);
        _assertAccounting();
    }

    function testFuzz_RoundTripDoesNotReturnMoreThanInput(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 100 ether);
        _buy(attacker, amount, 0);
        uint256 returned = _sellAll(attacker, 0);

        assertLe(returned, amount, "round trip cannot return more than input");
        _assertAccounting();
    }
}
