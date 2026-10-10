// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 15: failed-trade rollback and accounting-liability invariants.
/// @dev Local Foundry tests plus read-only CI preflight; no live-chain writes.
contract MEFailureAtomicityGate15Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 100 ether);
    }

    function test_BuySlippageFailureRollsBackAllAccounting() public {
        uint256 amount = 1 ether;
        uint256 impossibleMinOut = me.quoteBuy(amount) + 1;
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 kBefore = me.curveK();
        uint256 remainingBefore = me.remainingME();
        uint256 balanceBefore = me.balanceOf(alice);
        uint256 contractBalanceBefore = address(me).balance;
        uint256 aliceMONBefore = alice.balance;
        uint256 deadline = block.timestamp + 1 days;

        vm.prank(alice);
        vm.expectRevert(ME.SlippageExceeded.selector);
        me.buyME{value: amount}(impossibleMinOut, deadline);

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.remainingME(), remainingBefore);
        assertEq(me.balanceOf(alice), balanceBefore);
        assertEq(address(me).balance, contractBalanceBefore);
        assertEq(alice.balance, aliceMONBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_SellSlippageFailureRollsBackTokenAndMONBalances() public {
        uint256 amount = 5 ether;
        vm.prank(alice);
        me.buyME{value: amount}(0, block.timestamp + 1 days);

        uint256 tokens = me.balanceOf(alice);
        uint256 impossibleMinOut = me.quoteSellFor(alice, tokens) + 1;
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 kBefore = me.curveK();
        uint256 remainingBefore = me.remainingME();
        uint256 tokenBalanceBefore = me.balanceOf(alice);
        uint256 contractTokenBalanceBefore = me.balanceOf(address(me));
        uint256 contractMONBefore = address(me).balance;
        uint256 aliceMONBefore = alice.balance;

        vm.prank(alice);
        vm.expectRevert(ME.SlippageExceeded.selector);
        me.sellME(tokens, impossibleMinOut, block.timestamp + 1 days);

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.remainingME(), remainingBefore);
        assertEq(me.balanceOf(alice), tokenBalanceBefore);
        assertEq(me.balanceOf(address(me)), contractTokenBalanceBefore);
        assertEq(address(me).balance, contractMONBefore);
        assertEq(alice.balance, aliceMONBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_AccountingSnapshotMatchesPublicStateAfterTrade() public {
        vm.prank(alice);
        me.buyME{value: 3 ether}(0, block.timestamp + 1 days);

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
        assertEq(actualBalance, curveReserve + ownerFeeLiability + surplus);
    }

    function testFuzz_QuoteBuyFailureDoesNotMutateState(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 20 ether);
        uint256 quoted = me.quoteBuy(amount);
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 kBefore = me.curveK();
        uint256 remainingBefore = me.remainingME();
        uint256 balanceBefore = me.balanceOf(alice);
        uint256 contractBalanceBefore = address(me).balance;
        uint256 aliceMONBefore = alice.balance;

        vm.prank(alice);
        vm.expectRevert(ME.SlippageExceeded.selector);
        me.buyME{value: amount}(quoted + 1, block.timestamp + 1 days);

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.remainingME(), remainingBefore);
        assertEq(me.balanceOf(alice), balanceBefore);
        assertEq(address(me).balance, contractBalanceBefore);
        assertEq(alice.balance, aliceMONBefore);
        assertTrue(me.reserveSolvent());
    }
}
