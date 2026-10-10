// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 14: integer rounding, trade boundaries, and quote/execution parity.
/// @dev Local Foundry and read-only CI preflight only; no live-chain writes.
contract MERoundingBoundaryGate14Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _buy(address who, uint256 amount, uint256 minOut) internal returns (uint256 out) {
        vm.prank(who);
        out = me.buyME{value: amount}(minOut, block.timestamp + 1 days);
    }

    function test_FeeRoundingIsConservativeAndExactlyReconciles() public {
        uint256[8] memory amounts = [
            uint256(1), 2, 3, 9, 10, 99, 1 ether, 1234567890123456789
        ];

        for (uint256 i; i < amounts.length; ++i) {
            (uint256 poolFee, uint256 ownerFee, uint256 totalFee) =
                me.calculateFees(amounts[i]);
            assertEq(poolFee + ownerFee, totalFee, "fee components do not reconcile");
            assertGe(totalFee, amounts[i] / 100, "fee rounded below nominal 1% floor");
            assertLe(totalFee, amounts[i] / 100 + 1, "rounding excess exceeds one wei");
            assertLe(ownerFee, amounts[i] / 500, "owner fee exceeds 0.2% floor");
        }
    }

    function testFuzz_FeeSplitAlwaysReconciles(uint128 rawGross) public {
        uint256 gross = uint256(rawGross);
        (uint256 poolFee, uint256 ownerFee, uint256 totalFee) = me.calculateFees(gross);
        assertEq(poolFee + ownerFee, totalFee);
        if (gross > 0) {
            assertGe(totalFee, gross / 100);
            assertLe(totalFee, gross / 100 + 1);
            assertLe(ownerFee, gross / 500);
        }
    }

    function test_BuyBelowMinimumRevertsWithoutChangingState() public {
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 kBefore = me.curveK();
        uint256 aliceBefore = me.balanceOf(alice);

        vm.prank(alice);
        vm.expectRevert(ME.AmountTooSmall.selector);
        me.buyME{value: me.MIN_TRADE_MON() - 1}(0, block.timestamp + 1 days);

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.balanceOf(alice), aliceBefore);
    }

    function test_BuyQuoteMatchesExecutedOutputAtSameState() public {
        uint256 amount = 2 ether;
        uint256 quoted = me.quoteBuy(amount);
        uint256 received = _buy(alice, amount, quoted);
        assertEq(received, quoted, "quote and execution differ");
        assertEq(me.balanceOf(alice), quoted);
        assertTrue(me.reserveSolvent());
    }

    function test_SellQuoteMatchesExecutedOutputAtSameState() public {
        _buy(alice, 5 ether, 0);
        uint256 tokens = me.balanceOf(alice);
        uint256 quoted = me.quoteSellFor(alice, tokens);
        uint256 beforeBalance = alice.balance;

        vm.prank(alice);
        uint256 received = me.sellME(tokens, quoted, block.timestamp + 1 days);

        assertEq(received, quoted, "sell quote and execution differ");
        assertEq(alice.balance - beforeBalance, quoted, "recipient balance differs from return");
        assertEq(me.balanceOf(alice), 0);
        assertTrue(me.reserveSolvent());
    }

    function test_ExpiredBuyDeadlineDoesNotChangeState() public {
        uint256 reserveBefore = me.reserveMON();
        uint256 kBefore = me.curveK();
        vm.warp(block.timestamp + 2);

        vm.prank(bob);
        vm.expectRevert(ME.DeadlineExpired.selector);
        me.buyME{value: 1 ether}(0, block.timestamp - 1);

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.balanceOf(bob), 0);
    }

    function testFuzz_SuccessfulTradesKeepAccountingSolvent(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 50 ether);
        uint256 reserveBefore = me.reserveMON();
        _buy(alice, amount, 0);

        assertGe(me.reserveMON(), reserveBefore);
        assertTrue(me.reserveSolvent());
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees());
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY());
        assertEq(me.balanceOf(address(me)), me.remainingME());
        assertGe(me.curveK(), me.INITIAL_K());
    }
}
