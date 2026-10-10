// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 7: quote/execution consistency, slippage/deadline rollback,
/// transfer guards, and ownership handover invariants. Testnet only; no RPC.
contract MEHardeningGate7Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function test_BuyQuoteMatchesExecutedTokensAndFees() public {
        uint256 amount = 1 ether;
        (uint256 quotedME, uint256 quotedPoolFee, uint256 quotedOwnerFee) =
            me.quoteBuyDetailed(amount);

        vm.prank(alice);
        uint256 actualME = me.buyME{value: amount}(quotedME, block.timestamp + 1 days);

        assertEq(actualME, quotedME);
        assertEq(me.balanceOf(alice), quotedME);
        assertEq(me.reserveMON(), amount - quotedOwnerFee);
        assertEq(me.accruedOwnerFees(), quotedOwnerFee);
        assertGe(quotedPoolFee, 0);
        assertTrue(me.reserveSolvent());
    }

    function test_SellQuoteMatchesExecutionAndFeeAccounting() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);

        uint256 amount = me.balanceOf(alice);
        (uint256 quotedNet, uint256 poolFee, uint256 ownerFee) =
            me.quoteSellDetailed(alice, amount);
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 aliceBefore = alice.balance;

        vm.prank(alice);
        uint256 actualNet = me.sellME(amount, quotedNet, block.timestamp + 1 days);

        assertEq(actualNet, quotedNet);
        assertEq(alice.balance - aliceBefore, quotedNet);
        assertEq(me.reserveMON(), reserveBefore - (quotedNet + poolFee + ownerFee) + poolFee);
        assertEq(me.accruedOwnerFees(), feesBefore + ownerFee);
        assertEq(me.balanceOf(alice), 0);
        assertTrue(me.reserveSolvent());
    }

    function test_BuySlippageFailureLeavesAllStateUnchanged() public {
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 kBefore = me.curveK();
        uint256 remainingBefore = me.remainingME();
        uint256 balanceBefore = address(me).balance;

        vm.prank(alice);
        (bool ok,) = address(me).call{value: 1 ether}(
            abi.encodeCall(ME.buyME, (type(uint256).max, block.timestamp + 1 days))
        );
        assertFalse(ok, "impossible minMeOut must revert");
        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(me.curveK(), kBefore);
        assertEq(me.remainingME(), remainingBefore);
        assertEq(address(me).balance, balanceBefore);
        assertEq(me.balanceOf(alice), 0);
    }

    function test_ExpiredBuyAndSellDeadlinesRevertWithoutMutation() public {
        uint256 kBefore = me.curveK();
        vm.warp(10 days);
        vm.prank(alice);
        (bool buyOk,) = address(me).call{value: 1 ether}(
            abi.encodeCall(ME.buyME, (0, block.timestamp - 1))
        );
        assertFalse(buyOk, "expired buy must revert");
        assertEq(me.curveK(), kBefore);
        assertEq(me.balanceOf(alice), 0);

        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
        uint256 tokens = me.balanceOf(alice);
        uint256 reserveBefore = me.reserveMON();
        vm.prank(alice);
        (bool sellOk,) = address(me).call(
            abi.encodeCall(ME.sellME, (tokens, 0, block.timestamp - 1))
        );
        assertFalse(sellOk, "expired sell must revert");
        assertEq(me.balanceOf(alice), tokens);
        assertEq(me.reserveMON(), reserveBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_DirectMETransferIntoCurveRevertsWithoutChangingBalances() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
        uint256 tokens = me.balanceOf(alice);
        uint256 curveTokens = me.balanceOf(address(me));

        vm.prank(alice);
        (bool ok,) = address(me).call(
            abi.encodeCall(ME.transfer, (address(me), tokens / 2))
        );
        assertFalse(ok, "direct transfer into curve must revert");
        assertEq(me.balanceOf(alice), tokens);
        assertEq(me.balanceOf(address(me)), curveTokens);
    }

    function test_OwnershipTransferRequiresPendingOwnerAcceptance() public {
        address nextOwner = address(0xBEEF);
        me.transferOwnership(nextOwner);
        assertEq(me.owner(), address(this));
        assertEq(me.pendingOwner(), nextOwner);

        vm.prank(bob);
        (bool prematureClaim,) = address(me).call(
            abi.encodeCall(ME.claimOwnerFees, (payable(bob)))
        );
        assertFalse(prematureClaim, "non-owner cannot claim before acceptance");

        vm.prank(nextOwner);
        me.acceptOwnership();
        assertEq(me.owner(), nextOwner);
        assertEq(me.pendingOwner(), address(0));
    }

    function test_RenounceOwnershipRemainsDisabled() public {
        (bool ok,) = address(me).call(abi.encodeCall(ME.renounceOwnership, ()));
        assertFalse(ok, "ownership renunciation must stay disabled");
        assertEq(me.owner(), address(this));
    }
}
