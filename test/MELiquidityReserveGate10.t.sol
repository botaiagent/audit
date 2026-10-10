// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

/// @notice Gate 10: reserve liabilities, fee withdrawal and surplus attack tests.
/// @dev Local Foundry tests only. No RPC calls, wallet keys, or Testnet transactions.
contract MELiquidityReserveGate10Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);
    address internal bob = address(0xB0B);
    address internal ownerRecipient = address(0x0FEE);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 100 ether);
        vm.deal(bob, 100 ether);
    }

    function _buy(address who, uint256 amount) internal returns (uint256 out) {
        vm.prank(who);
        out = me.buyME{value: amount}(0, block.timestamp + 1 days);
    }

    function _sellAll(address who) internal returns (uint256 out) {
        uint256 amount = me.balanceOf(who);
        vm.prank(who);
        out = me.sellME(amount, 0, block.timestamp + 1 days);
    }

    function _assertLedger() internal view {
        assertTrue(me.reserveSolvent(), "reserve liabilities not solvent");
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees() + me.surplusMON(),
            "actual balance does not reconcile");
        assertEq(me.accountedMON(), me.reserveMON() + me.accruedOwnerFees(),
            "accountedMON mismatch");
        assertEq(me.virtualReserveMON(), me.BASE_MON() + me.reserveMON(),
            "virtual reserve mismatch");
        assertEq(me.balanceOf(address(me)), me.remainingME(), "ME curve ledger mismatch");
        assertEq(me.totalSupply(), me.TOTAL_SUPPLY(), "fixed supply changed");
        assertGe(me.curveK(), me.INITIAL_K(), "K regressed");
    }

    function test_BuySellAndFeeClaimNeverSpendCurveReserve() public {
        _buy(alice, 3 ether);
        _buy(bob, 2 ether);
        uint256 reserveBefore = me.reserveMON();
        uint256 feeLiability = me.accruedOwnerFees();
        assertGt(feeLiability, 0);

        vm.prank(alice);
        me.sellME(me.balanceOf(alice), 0, block.timestamp + 1 days);
        _assertLedger();

        uint256 reserveBeforeClaim = me.reserveMON();
        uint256 feesBeforeClaim = me.accruedOwnerFees();
        uint256 recipientBefore = ownerRecipient.balance;

        me.claimOwnerFees(payable(ownerRecipient));

        assertEq(ownerRecipient.balance - recipientBefore, feesBeforeClaim, "owner did not receive exact fees");
        assertEq(me.accruedOwnerFees(), 0, "fee liability not cleared");
        assertEq(me.reserveMON(), reserveBeforeClaim, "fee claim touched curve reserve");
        assertTrue(me.reserveMON() >= 0, "unreachable reserve check");
        assertTrue(reserveBefore > 0, "test setup should create curve liquidity");
        _assertLedger();
    }

    function test_ClaimFeesDoesNotChangeQuotesForSameCurveState() public {
        _buy(alice, 4 ether);
        uint256 amount = me.balanceOf(alice) / 3;
        uint256 quoteBefore = me.quoteSellFor(alice, amount);
        uint256 reserveBefore = me.reserveMON();
        uint256 fees = me.accruedOwnerFees();

        me.claimOwnerFees(payable(ownerRecipient));

        uint256 quoteAfter = me.quoteSellFor(alice, amount);
        assertEq(quoteAfter, quoteBefore, "fee withdrawal changed curve quote");
        assertEq(me.reserveMON(), reserveBefore, "fee withdrawal changed reserve");
        assertEq(me.accruedOwnerFees(), 0);
        assertEq(ownerRecipient.balance, fees);
        _assertLedger();
    }

    function test_ForcedSurplusCanBeRescuedButReserveAndFeesStayUntouched() public {
        _buy(alice, 2 ether);
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 contractBalanceBefore = address(me).balance;

        // Simulate forced native coin (e.g. selfdestruct); bypasses receive().
        vm.deal(address(me), contractBalanceBefore + 0.75 ether);
        assertEq(me.surplusMON(), 0.75 ether);

        uint256 recipientBefore = ownerRecipient.balance;
        me.rescueSurplusMON(ownerRecipient);

        assertEq(ownerRecipient.balance - recipientBefore, 0.75 ether);
        assertEq(me.reserveMON(), reserveBefore, "surplus rescue touched reserve");
        assertEq(me.accruedOwnerFees(), feesBefore, "surplus rescue touched fee liability");
        assertEq(me.surplusMON(), 0);
        _assertLedger();
    }

    function test_AttackerCannotClaimFeesOrRescueSurplus() public {
        _buy(alice, 1 ether);
        vm.deal(address(me), address(me).balance + 1 ether);
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 balanceBefore = address(me).balance;

        vm.prank(bob);
        vm.expectRevert();
        me.claimOwnerFees(payable(bob));

        vm.prank(bob);
        vm.expectRevert();
        me.rescueSurplusMON(bob);

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(address(me).balance, balanceBefore);
        _assertLedger();
    }

    function test_RejectingFeeReceiverCannotDrainOrCorruptAccounting() public {
        _buy(alice, 1 ether);
        RejectingMONReceiver rejector = new RejectingMONReceiver();
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 balanceBefore = address(me).balance;

        vm.expectRevert(ME.MONTransferFailed.selector);
        me.claimOwnerFees(payable(address(rejector)));

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), feesBefore);
        assertEq(address(me).balance, balanceBefore);
        _assertLedger();
    }

    function test_RepeatedClaimsCannotWithdrawSameFeeTwice() public {
        _buy(alice, 1 ether);
        uint256 fees = me.accruedOwnerFees();
        me.claimOwnerFees(payable(ownerRecipient));
        assertEq(ownerRecipient.balance, fees);

        vm.expectRevert(ME.NoFeesToClaim.selector);
        me.claimOwnerFees(payable(ownerRecipient));
        assertEq(ownerRecipient.balance, fees);
        assertEq(me.accruedOwnerFees(), 0);
        _assertLedger();
    }

    function test_SellCannotSpendAccruedOwnerFeeLiability() public {
        _buy(alice, 5 ether);
        _buy(bob, 5 ether);
        uint256 feesBefore = me.accruedOwnerFees();
        uint256 reserveBefore = me.reserveMON();

        _sellAll(alice);

        assertGe(me.accruedOwnerFees(), feesBefore, "sell improperly reduced owner fees");
        assertTrue(me.reserveSolvent(), "sell made liabilities insolvent");
        assertLt(me.reserveMON(), reserveBefore, "sell should release curve reserve");
        _assertLedger();
    }

    function testFuzz_AnySuccessfulBuyMaintainsExactAccounting(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 50 ether);
        _buy(alice, amount);
        _assertLedger();
    }

    function testFuzz_FeeClaimPreservesCurveReserveAndSolvency(uint96 rawAmount) public {
        uint256 amount = bound(uint256(rawAmount), me.MIN_TRADE_MON(), 50 ether);
        _buy(alice, amount);
        uint256 reserveBefore = me.reserveMON();
        uint256 feesBefore = me.accruedOwnerFees();
        assertGt(feesBefore, 0);

        me.claimOwnerFees(payable(ownerRecipient));

        assertEq(me.reserveMON(), reserveBefore);
        assertEq(me.accruedOwnerFees(), 0);
        assertEq(ownerRecipient.balance, feesBefore);
        _assertLedger();
    }
}

contract RejectingMONReceiver {
    receive() external payable {
        revert("reject MON");
    }
}
