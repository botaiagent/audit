// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

contract MECoreTest is Test {
    ME internal me;
    address internal owner = address(0xA11CE);
    address internal alice = address(0xB0B);

    function setUp() public {
        vm.prank(owner);
        me = new ME();
        vm.deal(alice, 1_000_000 ether);
    }

    function test_InitialSupplyIsHeldByCurve() public view {
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
        assertEq(me.balanceOf(address(me)), me.TOTAL_SUPPLY());
        assertEq(me.remainingME(), me.TOTAL_SUPPLY());
        assertEq(me.circulatingME(), 0);
        assertEq(me.reserveMON(), 0);
        assertTrue(me.reserveSolvent());
    }

    function testFuzz_BuyMaintainsSolvency(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), 0.01 ether, 100 ether);
        vm.prank(alice);
        me.buyME{value: amount}(0, block.timestamp + 1 days);
        assertTrue(me.reserveSolvent());
        assertEq(me.balanceOf(address(me)), me.remainingME());
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
        assertGe(address(me).balance, me.reserveMON());
        assertGt(me.balanceOf(alice), 0);
    }

    function testFuzz_BuyThenSellMaintainsSolvency(uint96 rawBuy, uint96 rawSellBps) public {
        uint256 amount = bound(uint256(rawBuy), 0.01 ether, 100 ether);
        vm.prank(alice);
        me.buyME{value: amount}(0, block.timestamp + 1 days);
        uint256 owned = me.balanceOf(alice);
        uint256 sellAmount = bound(uint256(rawSellBps), 1, 10_000) * owned / 10_000;
        if (sellAmount == 0) sellAmount = 1;
        // Partial sells below the contract's MON dust floor are expected to revert.
        // Use a full exit in that case, which the contract explicitly permits.
        if (sellAmount < owned) {
            // Dust-sized quote can revert; test the permitted full exit instead.
            try me.quoteSellFor(alice, sellAmount) returns (uint256 quotedOut) {
                if (quotedOut < me.MIN_TRADE_MON()) sellAmount = owned;
            } catch {
                sellAmount = owned;
            }
        }
        vm.prank(alice);
        me.sellME(sellAmount, 0, block.timestamp + 1 days);
        assertTrue(me.reserveSolvent());
        assertEq(me.balanceOf(address(me)), me.remainingME());
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
        assertGe(address(me).balance, me.reserveMON());
    }

    function test_RevertOnDirectMON() public {
        vm.prank(alice);
        (bool ok,) = address(me).call{value: 1 ether}("");
        assertFalse(ok);
    }

    function test_RevertOnDirectTransferToCurve() public {
        vm.prank(alice);
        vm.expectRevert();
        me.transfer(address(me), 1);
    }

    function test_RevertOnExpiredBuyDeadline() public {
        vm.warp(10 days);
        vm.prank(alice);
        vm.expectRevert(ME.DeadlineExpired.selector);
        me.buyME{value: 1 ether}(0, block.timestamp - 1);
    }

    function test_RevertOnSlippageBuy() public {
        vm.prank(alice);
        vm.expectRevert(ME.SlippageExceeded.selector);
        me.buyME{value: 1 ether}(type(uint256).max, block.timestamp + 1 days);
    }

    function test_QuoteBuyIsPositiveForOrdinaryTrade() public view {
        assertGt(me.quoteBuy(1 ether), 0);
    }

    function test_SellRevertsOnExpiredDeadline() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
        uint256 owned = me.balanceOf(alice);

        vm.warp(10 days);
        vm.prank(alice);
        vm.expectRevert(ME.DeadlineExpired.selector);
        me.sellME(owned, 0, block.timestamp - 1);
    }

    function test_SellRevertsWhenSlippageMinimumTooHigh() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
        uint256 owned = me.balanceOf(alice);
        uint256 quotedOut = me.quoteSellFor(alice, owned);

        vm.prank(alice);
        vm.expectRevert(ME.SlippageExceeded.selector);
        me.sellME(owned, quotedOut + 1, block.timestamp + 1 days);
    }

    function test_CalculateFeesOneMONIsOnePercentSplit() public view {
        (uint256 poolFee, uint256 ownerFee, uint256 totalFee) =
            me.calculateFees(1 ether);

        assertEq(poolFee, 0.008 ether);
        assertEq(ownerFee, 0.002 ether);
        assertEq(totalFee, 0.01 ether);
    }

    function test_OwnerCanClaimAccruedFees() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
        uint256 fees = me.accruedOwnerFees();
        assertEq(fees, 0.002 ether);

        uint256 ownerBalanceBefore = owner.balance;
        vm.prank(owner);
        me.claimOwnerFees(payable(owner));

        assertEq(me.accruedOwnerFees(), 0);
        assertEq(owner.balance - ownerBalanceBefore, fees);
        assertTrue(me.reserveSolvent());
    }

    function test_NonOwnerCannotClaimFees() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);

        vm.prank(alice);
        vm.expectRevert();
        me.claimOwnerFees(payable(alice));
    }

    function test_OwnerCanRescueForcedMONSurplusOnly() public {
        vm.deal(address(me), address(me).balance + 1 ether);
        uint256 reserveBefore = me.reserveMON();
        uint256 recipientBefore = alice.balance;

        vm.prank(owner);
        me.rescueSurplusMON(alice);

        assertEq(alice.balance - recipientBefore, 1 ether);
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees());
        assertTrue(me.reserveSolvent());
    }

    function test_NonOwnerCannotRescueSurplus() public {
        vm.deal(address(me), 1 ether);
        vm.prank(alice);
        vm.expectRevert();
        me.rescueSurplusMON(alice);
    }

    function test_OwnershipTransferRequiresAcceptance() public {
        address nextOwner = address(0xCAFE);

        vm.prank(owner);
        me.transferOwnership(nextOwner);
        assertEq(me.owner(), owner);
        assertEq(me.pendingOwner(), nextOwner);

        vm.prank(nextOwner);
        me.acceptOwnership();
        assertEq(me.owner(), nextOwner);
        assertEq(me.pendingOwner(), address(0));
    }

    function test_QuoteBuyMatchesExecutedBuy() public {
        uint256 monIn = 2 ether;
        uint256 expectedME = me.quoteBuy(monIn);

        vm.prank(alice);
        me.buyME{value: monIn}(expectedME, block.timestamp + 1 days);

        assertEq(me.balanceOf(alice), expectedME);
        assertTrue(me.reserveSolvent());
    }

    function test_QuoteSellMatchesExecutedSell() public {
        vm.prank(alice);
        me.buyME{value: 2 ether}(0, block.timestamp + 1 days);

        uint256 meIn = me.balanceOf(alice);
        uint256 expectedMON = me.quoteSellFor(alice, meIn);
        uint256 beforeBalance = alice.balance;

        vm.prank(alice);
        me.sellME(meIn, expectedMON, block.timestamp + 1 days);

        assertEq(alice.balance - beforeBalance, expectedMON);
        assertEq(me.balanceOf(alice), 0);
        assertTrue(me.reserveSolvent());
    }

    function test_FeeRoundingBoundaries() public view {
        (uint256 pool1, uint256 owner1, uint256 total1) = me.calculateFees(1);
        assertEq(total1, 1);
        assertEq(owner1, 0);
        assertEq(pool1, 1);

        (uint256 pool50, uint256 owner50, uint256 total50) = me.calculateFees(50);
        assertEq(total50, 1);
        assertEq(owner50, 0);
        assertEq(pool50, 1);

        (uint256 pool500, uint256 owner500, uint256 total500) = me.calculateFees(500);
        assertEq(total500, 5);
        assertEq(owner500, 1);
        assertEq(pool500, 4);

        (uint256 pool10000, uint256 owner10000, uint256 total10000) =
            me.calculateFees(10_000);
        assertEq(total10000, 100);
        assertEq(owner10000, 20);
        assertEq(pool10000, 80);
    }

    function test_CurveKNeverDecreasesAcrossBuyAndSell() public {
        uint256 initialK = me.curveK();

        vm.prank(alice);
        me.buyME{value: 10 ether}(0, block.timestamp + 1 days);
        uint256 afterBuyK = me.curveK();
        assertGe(afterBuyK, initialK);

        uint256 owned = me.balanceOf(alice);
        vm.prank(alice);
        me.sellME(owned, 0, block.timestamp + 1 days);

        assertGe(me.curveK(), afterBuyK);
        assertTrue(me.reserveSolvent());
    }

    function test_OwnerCannotRenounceOwnership() public {
        vm.prank(owner);
        vm.expectRevert(ME.RenounceDisabled.selector);
        me.renounceOwnership();
    }
}
