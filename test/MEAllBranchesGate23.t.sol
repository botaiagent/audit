// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Gate 23: consolidated branch-targeted regression suite.
/// @dev Local Foundry/CI only. No live-chain transactions.
contract MEAllBranchesGate23Test is Test {
    ME internal me;
    address internal trader = address(0xBEEF);
    address internal other = address(0xCAFE);

    function setUp() public {
        me = new ME();
        vm.deal(trader, 100 ether);
        vm.deal(other, 100 ether);
    }

    function test_InitialViewsAndAccountingSnapshot() public view {
        assertEq(me.decimals(), 18);
        assertEq(me.remainingME(), ME.TOTAL_SUPPLY());
        assertEq(me.circulatingME(), 0);
        assertEq(me.virtualReserveMON(), ME.BASE_MON());
        assertEq(me.actualMON(), 0);
        assertEq(me.surplusMON(), 0);
        assertFalse(me.reserveSolvent() == false);
        assertEq(me.curveReserveMON(), 0);
        assertEq(me.accountedMON(), 0);
        (uint256 actual, uint256 reserve, uint256 fees, uint256 surplus, uint256 k, uint256 left, bool solvent) = me.accountingStatus();
        assertEq(actual, 0);
        assertEq(reserve, 0);
        assertEq(fees, 0);
        assertEq(surplus, 0);
        assertEq(k, ME.INITIAL_K());
        assertEq(left, ME.TOTAL_SUPPLY());
        assertTrue(solvent);
    }

    function test_CurrentPriceAndQuoteBuyValid() public view {
        assertGt(me.currentPrice(), 0);
        assertGt(me.quoteBuy(1 ether), 0);
        (uint256 out, uint256 poolFee, uint256 ownerFee) = me.quoteBuyDetailed(1 ether);
        assertGt(out, 0);
        assertGt(poolFee, 0);
        assertGt(ownerFee, 0);
    }

    function test_BuyRejectsZeroTooSmallExpiredAndSlippage() public {
        vm.expectRevert(ME.ZeroAmount.selector);
        me.quoteBuy(0);
        vm.expectRevert(ME.AmountTooSmall.selector);
        me.quoteBuy(ME.MIN_TRADE_MON() - 1);
        vm.expectRevert(ME.DeadlineExpired.selector);
        vm.prank(trader);
        me.buyME{value: 1 ether}(0, block.timestamp - 1);
        vm.expectRevert(ME.SlippageExceeded.selector);
        vm.prank(trader);
        me.buyME{value: 1 ether}(type(uint256).max, block.timestamp);
    }

    function test_SellRejectsZeroInsufficientAndPartialDust() public {
        vm.expectRevert(ME.ZeroAmount.selector);
        me.quoteSellFor(trader, 0);
        vm.expectRevert(ME.InsufficientME.selector);
        me.quoteSellFor(trader, 1);
        vm.prank(trader);
        me.buyME{value: 1 ether}(0, block.timestamp);
        uint256 bal = me.balanceOf(trader);
        vm.expectRevert(ME.AmountTooSmall.selector);
        vm.prank(trader);
        me.sellME(1, 0, block.timestamp);
        vm.expectRevert(ME.InsufficientME.selector);
        vm.prank(other);
        me.sellME(1, 0, block.timestamp);
        assertGt(bal, 0);
    }

    function test_SellExpiryAndSlippageRollback() public {
        vm.prank(trader);
        me.buyME{value: 2 ether}(0, block.timestamp);
        uint256 amount = me.balanceOf(trader) / 2;
        vm.expectRevert(ME.DeadlineExpired.selector);
        vm.prank(trader);
        me.sellME(amount, 0, block.timestamp - 1);
        vm.expectRevert(ME.SlippageExceeded.selector);
        vm.prank(trader);
        me.sellME(amount, type(uint256).max, block.timestamp);
        assertTrue(me.reserveSolvent());
    }

    function test_FullBalanceDustExitAllowedAndFeeClaimBranches() public {
        vm.prank(trader);
        me.buyME{value: 1 ether}(0, block.timestamp);
        uint256 bal = me.balanceOf(trader);
        vm.prank(trader);
        me.sellME(bal, 0, block.timestamp);
        assertEq(me.balanceOf(trader), 0);

        vm.expectRevert(ME.NoFeesToClaim.selector);
        me.claimOwnerFees(payable(other));
        vm.expectRevert(ME.ZeroAddress.selector);
        me.claimOwnerFees(payable(address(0)));
    }

    function test_OwnerAccessAndRescueGuardBranches() public {
        vm.prank(other);
        vm.expectRevert();
        me.claimOwnerFees(payable(other));
        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueSurplusMON(address(0));
        vm.expectRevert(ME.NothingToRescue.selector);
        me.rescueSurplusMON(other);
        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueERC20(address(0), other);
        vm.expectRevert(ME.CannotRescueME.selector);
        me.rescueERC20(address(me), other);
        vm.expectRevert(ME.InvalidTokenContract.selector);
        me.rescueERC20(address(0x1234), other);
        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueERC721(address(0), 1, other);
        vm.expectRevert(ME.CannotRescueME.selector);
        me.rescueERC721(address(me), 1, other);
        vm.expectRevert(ME.InvalidTokenContract.selector);
        me.rescueERC721(address(0x1234), 1, other);
        vm.expectRevert(ME.ZeroAddress.selector);
        me.rescueERC1155(address(0), 1, other);
        vm.expectRevert(ME.CannotRescueME.selector);
        me.rescueERC1155(address(me), 1, other);
        vm.expectRevert(ME.InvalidTokenContract.selector);
        me.rescueERC1155(address(0x1234), 1, other);
    }

    function test_RescueERC20EmptyAndRenounceDisabled() public {
        ERC20 foreign = new ERC20("Foreign", "F") {};
        vm.expectRevert(ME.NothingToRescue.selector);
        me.rescueERC20(address(foreign), other);
        vm.expectRevert(ME.RenounceDisabled.selector);
        me.renounceOwnership();
    }

    function test_DirectMONAndDirectMETransferToContractRejected() public {
        (bool ok,) = address(me).call{value: 1 wei}("");
        assertFalse(ok);
        vm.prank(trader);
        me.buyME{value: 1 ether}(0, block.timestamp);
        vm.expectRevert(ME.DirectMEToContractNotAllowed.selector);
        vm.prank(trader);
        me.transfer(address(me), 1);
    }

    function test_CalculateFeesRoundingBoundaries() public view {
        (uint256 p0, uint256 o0, uint256 t0) = me.calculateFees(0);
        assertEq(p0 + o0, t0);
        (uint256 p1, uint256 o1, uint256 t1) = me.calculateFees(1);
        assertEq(p1 + o1, t1);
        (uint256 p2, uint256 o2, uint256 t2) = me.calculateFees(10_000);
        assertEq(p2, 80);
        assertEq(o2, 20);
        assertEq(t2, 100);
    }

    function test_ForcedSurplusCanBeRescuedWithoutBreakingSolvency() public {
        vm.deal(address(me), 1 ether);
        assertEq(me.surplusMON(), 1 ether);
        me.rescueSurplusMON(other);
        assertEq(me.surplusMON(), 0);
        assertTrue(me.reserveSolvent());
    }
}
