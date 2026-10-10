// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

contract Gate21EmptyERC20 {
    function balanceOf(address) external pure returns (uint256) { return 0; }
    function transfer(address, uint256) external pure returns (bool) { return true; }
}

contract Gate21RejectingReceiver {
    receive() external payable { revert("reject MON"); }
}

/// @notice Gate 21 targets uncovered conditional outcomes in quote, transfer guards and rescue paths.
/// @dev Local Foundry tests only; no live-chain transactions.
contract MEBranchCoverageGate21Test is Test {
    ME internal me;
    address internal trader = address(0xBEEF);
    address internal recipient = address(0xCAFE);

    function setUp() public {
        me = new ME();
        vm.deal(trader, 10 ether);
        vm.prank(trader);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
    }

    function test_QuoteBuyRejectsZeroAndBelowMinimum() public {
        vm.expectRevert(ME.ZeroAmount.selector);
        me.quoteBuy(0);
        vm.expectRevert(ME.AmountTooSmall.selector);
        me.quoteBuy(ME.MIN_TRADE_MON() - 1);
    }

    function test_QuoteSellRejectsZeroAndInsufficientBalance() public {
        vm.expectRevert(ME.ZeroAmount.selector);
        me.quoteSellFor(trader, 0);
        vm.expectRevert(ME.InsufficientME.selector);
        me.quoteSellFor(trader, me.balanceOf(trader) + 1);
    }

    function test_SurplusZeroWhenBalanceDoesNotExceedLiabilities() public {
        assertEq(me.surplusMON(), 0);
        assertTrue(me.reserveSolvent());
        assertEq(me.actualMON(), me.accountedMON());
    }

    function test_RescueERC20RejectsEOAAndEmptyBalance() public {
        vm.expectRevert(ME.InvalidTokenContract.selector);
        me.rescueERC20(address(0x1234), recipient);

        Gate21EmptyERC20 emptyToken = new Gate21EmptyERC20();
        vm.expectRevert(ME.NothingToRescue.selector);
        me.rescueERC20(address(emptyToken), recipient);
    }

    function test_RescueERC20RejectsZeroAddresses() public {
        Gate21EmptyERC20 token = new Gate21EmptyERC20();
        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueERC20(address(0), recipient);
        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueERC20(address(token), address(0));
    }

    function test_RescueERC1155RejectsZeroAddressesAndEmptyBalance() public {
        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueERC1155(address(0), 1, recipient);

        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueERC1155(address(0x1234), 1, address(0));

        // A deployed contract passes the code check; no token balance exists for this ID.
        vm.expectRevert();
        me.rescueERC1155(address(this), 1, recipient);
    }

    function test_ClaimOwnerFeesRejectsReceiverThatRevertsAndRollsBack() public {
        vm.prank(trader);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
        uint256 feesBefore = me.accruedOwnerFees();
        assertGt(feesBefore, 0);

        Gate21RejectingReceiver rejecting = new Gate21RejectingReceiver();
        vm.expectRevert(ME.MONTransferFailed.selector);
        me.claimOwnerFees(payable(address(rejecting)));

        assertEq(me.accruedOwnerFees(), feesBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_DirectTransferToContractRejectsPartialAndOrdinaryTransfers() public {
        vm.prank(trader);
        vm.expectRevert(ME.DirectMEToContractNotAllowed.selector);
        me.transfer(address(me), 1);

        vm.expectRevert(ME.DirectMEToContractNotAllowed.selector);
        me.transfer(address(me), 0);
    }

    function test_AccountingSnapshotZeroSurplusAndSolvencyAgree() public view {
        (uint256 actual, uint256 reserve, uint256 fees, uint256 surplus, uint256 k, uint256 remaining, bool solvent) =
            me.accountingStatus();
        assertEq(actual, reserve + fees);
        assertEq(surplus, 0);
        assertEq(k, me.curveK());
        assertEq(remaining, me.remainingME());
        assertTrue(solvent);
    }
}
