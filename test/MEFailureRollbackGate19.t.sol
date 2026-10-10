// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 19: failure atomicity across deadline, slippage, and invalid trades.
/// @dev Foundry/CI tests only. No live-chain transactions.
contract MEFailureRollbackGate19Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 100 ether);
    }

    function _assertState(
        uint256 reserve,
        uint256 fees,
        uint256 k,
        uint256 remaining,
        uint256 aliceTokens,
        uint256 contractTokens,
        uint256 contractMON,
        uint256 aliceMON
    ) internal view {
        assertEq(me.reserveMON(), reserve, "curve reserve changed");
        assertEq(me.accruedOwnerFees(), fees, "owner fee liability changed");
        assertEq(me.curveK(), k, "curve K changed");
        assertEq(me.remainingME(), remaining, "remaining ME changed");
        assertEq(me.balanceOf(alice), aliceTokens, "trader ME changed");
        assertEq(me.balanceOf(address(me)), contractTokens, "contract ME changed");
        assertEq(address(me).balance, contractMON, "contract MON changed");
        assertEq(alice.balance, aliceMON, "trader MON changed");
        assertTrue(me.reserveSolvent(), "reserve became insolvent");
    }

    function test_ExpiredBuyRollsBackValueAndAllState() public {
        uint256 reserve = me.reserveMON();
        uint256 fees = me.accruedOwnerFees();
        uint256 k = me.curveK();
        uint256 remaining = me.remainingME();
        uint256 aliceTokens = me.balanceOf(alice);
        uint256 contractTokens = me.balanceOf(address(me));
        uint256 contractMON = address(me).balance;
        uint256 aliceMON = alice.balance;
        uint256 deadline = block.timestamp - 1;

        vm.prank(alice);
        vm.expectRevert(ME.DeadlineExpired.selector);
        me.buyME{value: 1 ether}(0, deadline);

        _assertState(reserve, fees, k, remaining, aliceTokens, contractTokens, contractMON, aliceMON);
    }

    function test_ExpiredSellRollsBackTokenTransferAndAccounting() public {
        vm.prank(alice);
        me.buyME{value: 5 ether}(0, block.timestamp + 1 days);

        uint256 tokens = me.balanceOf(alice);
        uint256 reserve = me.reserveMON();
        uint256 fees = me.accruedOwnerFees();
        uint256 k = me.curveK();
        uint256 remaining = me.remainingME();
        uint256 contractTokens = me.balanceOf(address(me));
        uint256 contractMON = address(me).balance;
        uint256 aliceMON = alice.balance;
        uint256 deadline = block.timestamp - 1;

        vm.prank(alice);
        vm.expectRevert(ME.DeadlineExpired.selector);
        me.sellME(tokens, 0, deadline);

        _assertState(reserve, fees, k, remaining, tokens, contractTokens, contractMON, aliceMON);
    }

    function test_InvalidZeroSellRollsBackWithoutChangingState() public {
        uint256 reserve = me.reserveMON();
        uint256 fees = me.accruedOwnerFees();
        uint256 k = me.curveK();
        uint256 remaining = me.remainingME();
        uint256 aliceTokens = me.balanceOf(alice);
        uint256 contractTokens = me.balanceOf(address(me));
        uint256 contractMON = address(me).balance;
        uint256 aliceMON = alice.balance;

        vm.prank(alice);
        vm.expectRevert(ME.ZeroAmount.selector);
        me.sellME(0, 0, block.timestamp + 1 days);

        _assertState(reserve, fees, k, remaining, aliceTokens, contractTokens, contractMON, aliceMON);
    }

    function testFuzz_BuySlippageRollbackPreservesFullSnapshot(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 50 ether);
        uint256 impossibleMinOut = me.quoteBuy(amount) + 1;
        uint256 reserve = me.reserveMON();
        uint256 fees = me.accruedOwnerFees();
        uint256 k = me.curveK();
        uint256 remaining = me.remainingME();
        uint256 aliceTokens = me.balanceOf(alice);
        uint256 contractTokens = me.balanceOf(address(me));
        uint256 contractMON = address(me).balance;
        uint256 aliceMON = alice.balance;

        vm.prank(alice);
        vm.expectRevert(ME.SlippageExceeded.selector);
        me.buyME{value: amount}(impossibleMinOut, block.timestamp + 1 days);

        _assertState(reserve, fees, k, remaining, aliceTokens, contractTokens, contractMON, aliceMON);
    }

    function testFuzz_SellSlippageRollbackPreservesFullSnapshot(uint96 rawAmount) public {
        uint256 buyAmount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 50 ether);
        vm.prank(alice);
        me.buyME{value: buyAmount}(0, block.timestamp + 1 days);

        uint256 tokens = me.balanceOf(alice);
        uint256 impossibleMinOut = me.quoteSellFor(alice, tokens) + 1;
        uint256 reserve = me.reserveMON();
        uint256 fees = me.accruedOwnerFees();
        uint256 k = me.curveK();
        uint256 remaining = me.remainingME();
        uint256 contractTokens = me.balanceOf(address(me));
        uint256 contractMON = address(me).balance;
        uint256 aliceMON = alice.balance;

        vm.prank(alice);
        vm.expectRevert(ME.SlippageExceeded.selector);
        me.sellME(tokens, impossibleMinOut, block.timestamp + 1 days);

        _assertState(reserve, fees, k, remaining, tokens, contractTokens, contractMON, aliceMON);
    }
}
