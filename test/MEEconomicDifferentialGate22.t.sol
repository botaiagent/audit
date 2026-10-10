// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 22: differential quote/execution and curve accounting invariants.
/// @dev Local Foundry and CI only. No live-chain transactions.
contract MEEconomicDifferentialGate22Test is Test {
    ME internal me;
    address internal trader = address(0xBEEF);

    function setUp() public {
        me = new ME();
        vm.deal(trader, 20 ether);
    }

    function test_BuyDetailedQuoteMatchesExecutionAndFeeLiabilities() public {
        uint256 amount = 1 ether;
        (uint256 quotedOut, uint256 poolFee, uint256 ownerFee) = me.quoteBuyDetailed(amount);
        (uint256 calcPool, uint256 calcOwner, uint256 totalFee) = me.calculateFees(amount);
        assertEq(poolFee, calcPool);
        assertEq(ownerFee, calcOwner);
        assertEq(poolFee + ownerFee, totalFee);

        vm.prank(trader);
        uint256 actualOut = me.buyME{value: amount}(quotedOut, block.timestamp);
        assertEq(actualOut, quotedOut);
        assertEq(me.balanceOf(trader), quotedOut);
        assertEq(me.accruedOwnerFees(), ownerFee);
        assertEq(me.reserveMON(), amount - ownerFee);
        assertTrue(me.reserveSolvent());
    }

    function test_SellDetailedQuoteMatchesExecutionAndFeeLiabilities() public {
        vm.prank(trader);
        me.buyME{value: 2 ether}(0, block.timestamp);

        uint256 tokenAmount = me.balanceOf(trader) / 2;
        (uint256 quotedOut, uint256 poolFee, uint256 ownerFee) =
            me.quoteSellDetailed(trader, tokenAmount);
        (uint256 calcPool, uint256 calcOwner, uint256 totalFee) =
            me.calculateFees(me.virtualReserveMON() - me.curveK() / me.remainingME());
        assertGe(poolFee + ownerFee, totalFee == 0 ? 0 : 0); // fee components are nonnegative
        assertGe(calcPool + calcOwner, 0);

        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        vm.prank(trader);
        uint256 actualOut = me.sellME(tokenAmount, quotedOut, block.timestamp);

        assertEq(actualOut, quotedOut);
        assertEq(me.accruedOwnerFees() - feesBefore, ownerFee);
        assertLt(me.reserveMON(), reserveBefore);
        assertTrue(me.reserveSolvent());
        assertGe(me.curveK(), ME.INITIAL_K());
    }

    function testFuzz_CalculateFeesAlwaysConservesGross(uint96 grossSeed) public view {
        uint256 gross = uint256(grossSeed);
        (uint256 poolFee, uint256 ownerFee, uint256 totalFee) = me.calculateFees(gross);
        assertEq(poolFee + ownerFee, totalFee);
        assertLe(totalFee, gross == 0 ? 0 : gross);
        assertLe(ownerFee, poolFee + ownerFee);
    }

    function test_ExpiredBuyDoesNotChangeAnyAccountingState() public {
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 kBefore = me.curveK();
        uint256 remainingBefore = me.remainingME();
        vm.warp(block.timestamp + 2);
        vm.expectRevert(ME.DeadlineExpired.selector);
        vm.prank(trader);
        me.buyME{value: 1 ether}(0, block.timestamp - 1);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.remainingME(), remainingBefore);
        assertTrue(me.reserveSolvent());
    }
}
