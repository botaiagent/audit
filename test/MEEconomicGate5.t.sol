// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

contract MEEconomicGate5Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal carol = address(0xCA401);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 1_000 ether);
        vm.deal(bob, 1_000 ether);
        vm.deal(carol, 1_000 ether);
    }

    function testFuzz_FeeSplitAlwaysConservesGross(uint128 rawGross) public view {
        uint256 gross = bound(uint256(rawGross), 0, type(uint128).max);
        (uint256 poolFee, uint256 ownerFee, uint256 totalFee) = me.calculateFees(gross);
        assertEq(poolFee + ownerFee, totalFee);
        if (gross == 0) {
            assertEq(totalFee, 0);
        } else {
            assertLe(totalFee, gross);
            assertLe(ownerFee, gross);
            assertLe(poolFee, totalFee);
        }
    }

    function testFuzz_CurveKNeverDecreasesAfterBuyAndFullExit(uint96 rawBuy) public {
        uint256 amount = bound(uint256(rawBuy), 0.01 ether, 100 ether);
        uint256 initialK = me.curveK();

        vm.prank(alice);
        me.buyME{value: amount}(0, block.timestamp + 1 days);
        uint256 kAfterBuy = me.curveK();
        assertGe(kAfterBuy, initialK);

        uint256 owned = me.balanceOf(alice);
        vm.prank(alice);
        me.sellME(owned, 0, block.timestamp + 1 days);
        assertGe(me.curveK(), kAfterBuy);
        assertTrue(me.reserveSolvent());
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees());
    }

    function test_MultipleTradersCannotBreakAccounting() public {
        vm.prank(alice);
        me.buyME{value: 2 ether}(0, block.timestamp + 1 days);
        vm.prank(bob);
        me.buyME{value: 3 ether}(0, block.timestamp + 1 days);

        uint256 aliceBalance = me.balanceOf(alice);
        vm.prank(alice);
        me.sellME(aliceBalance, 0, block.timestamp + 1 days);

        vm.prank(carol);
        me.buyME{value: 0.5 ether}(0, block.timestamp + 1 days);

        uint256 bobBalance = me.balanceOf(bob);
        vm.prank(bob);
        me.sellME(bobBalance, 0, block.timestamp + 1 days);

        assertTrue(me.reserveSolvent());
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees());
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
        assertEq(me.balanceOf(address(me)), me.remainingME());
        assertGe(me.curveK(), me.INITIAL_K());
    }

    function test_BuyBelowMinimumRevertsWithoutStateChange() public {
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 kBefore = me.curveK();

        vm.startPrank(alice);
        vm.expectRevert(ME.AmountTooSmall.selector);
        me.buyME{value: me.MIN_TRADE_MON() - 1}(0, block.timestamp + 1 days);
        vm.stopPrank();

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.balanceOf(alice), 0);
        assertTrue(me.reserveSolvent());
    }

    function test_FullExitWorksEvenWhenSmallPartialSaleWouldBeDust() public {
        vm.prank(alice);
        me.buyME{value: 0.02 ether}(0, block.timestamp + 1 days);
        uint256 owned = me.balanceOf(alice);
        assertGt(owned, 1);

        vm.startPrank(alice);
        vm.expectRevert(ME.AmountTooSmall.selector);
        me.sellME(owned / 2, 0, block.timestamp + 1 days);
        vm.stopPrank();

        vm.prank(alice);
        me.sellME(owned, 0, block.timestamp + 1 days);
        assertEq(me.balanceOf(alice), 0);
        assertTrue(me.reserveSolvent());
    }

    function testFuzz_AccountingStatusAlwaysMatchesLedger(uint96 rawBuy) public {
        uint256 amount = bound(uint256(rawBuy), 0.01 ether, 100 ether);
        vm.prank(alice);
        me.buyME{value: amount}(0, block.timestamp + 1 days);

        (
            uint256 actualBalance,
            uint256 curveReserve,
            uint256 ownerFeeLiability,
            uint256 surplus,
            uint256 liveK,
            uint256 tokensRemaining,
            bool solvent
        ) = me.accountingStatus();

        assertEq(actualBalance, address(me).balance);
        assertEq(curveReserve, me.reserveMON());
        assertEq(ownerFeeLiability, me.accruedOwnerFees());
        assertEq(surplus, me.surplusMON());
        assertEq(liveK, me.curveK());
        assertEq(tokensRemaining, me.remainingME());
        assertTrue(solvent);
        assertEq(actualBalance, curveReserve + ownerFeeLiability);
    }
}
