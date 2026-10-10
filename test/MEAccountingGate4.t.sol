// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {ME} from "../src/ME.sol";

contract MEAccountingGate4Test is Test {
    ME internal me;
    address internal alice = address(0xA11CE);

    function setUp() public {
        me = new ME();
        vm.deal(alice, 100 ether);
    }

    function test_AccountingSnapshotMatchesPublicStateAfterBuy() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);

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

    function test_BuyAndSellFeesRemainFullyAccounted() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);

        uint256 ownerFeesAfterBuy = me.accruedOwnerFees();
        assertEq(ownerFeesAfterBuy, 0.002 ether);

        uint256 owned = me.balanceOf(alice);
        uint256 expectedNet = me.quoteSellFor(alice, owned);

        vm.prank(alice);
        me.sellME(owned, expectedNet, block.timestamp + 1 days);

        assertGt(me.accruedOwnerFees(), ownerFeesAfterBuy);
        assertTrue(me.reserveSolvent());
        assertEq(address(me).balance, me.reserveMON() + me.accruedOwnerFees());
        assertEq(me.balanceOf(alice), 0);
    }

    function test_OwnerCannotRescueMETokenItself() public {
        vm.expectRevert(ME.CannotRescueME.selector);
        me.rescueERC20(address(me), address(this));
    }

    function test_ClaimFeesToZeroAddressRevertsWithoutChangingLiability() public {
        vm.prank(alice);
        me.buyME{value: 1 ether}(0, block.timestamp + 1 days);
        uint256 feesBefore = me.accruedOwnerFees();

        vm.expectRevert(ME.ZeroAddress.selector);
        me.claimOwnerFees(payable(address(0)));

        assertEq(me.accruedOwnerFees(), feesBefore);
        assertTrue(me.reserveSolvent());
    }

    function test_ClaimFeesWhenNoneAccruedReverts() public {
        vm.expectRevert(ME.NoFeesToClaim.selector);
        me.claimOwnerFees(payable(address(this)));
    }
}
