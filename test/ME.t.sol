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
}
